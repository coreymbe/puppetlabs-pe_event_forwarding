#!/opt/puppetlabs/puppet/bin/ruby
require 'find'
require 'yaml'

require_relative 'api/activity'
require_relative 'api/orchestrator'
require_relative 'util/lockfile'
require_relative 'util/http'
require_relative 'util/pe_http'
require_relative 'util/index'
require_relative 'util/plan_index'
require_relative 'util/processor'
require_relative 'util/logger'

confdir   = ARGV[0] || '/etc/puppetlabs/pe_event_forwarding'
logpath   = ARGV[1] || '/var/log/puppetlabs/pe_event_forwarding/pe_event_forwarding.log'
lockdir   = ARGV[2] || '/opt/puppetlabs/pe_event_forwarding/cache/state'

def main(confdir, logpath, lockdir)
  common_event_start_time = Time.now
  settings = YAML.safe_load(File.read("#{confdir}/collection_settings.yaml"))
  secrets = YAML.safe_load(File.read("#{confdir}/collection_secrets.yaml"))
  log = PeEventForwarding::Logger.new(logpath, settings['log_rotation'])
  log.level = PeEventForwarding::Logger::LOG_LEVELS[settings['log_level']]
  lockfile = PeEventForwarding::Lockfile.new(lockdir)

  if lockfile.already_running?
    log.warn('previous run is not complete')
    exit
  end

  lockfile.write_lockfile
  if lockfile.lockfile_exists?
    log.debug('Lockfile was successfully created.')
  else
    log.error('Lockfile creation failed.')
  end
  index = PeEventForwarding::Index.new(confdir)
  plan_index = PeEventForwarding::PlanIndex.new(confdir)
  data = {}

  client_options = {
    username:    secrets['pe_username'],
    password:    secrets['pe_password'],
    token:       secrets['pe_token'],
    ssl_verify:  false,
    log: log
  }

  timeout = settings['timeout'] || 60

  orchestrator = PeEventForwarding::Orchestrator.new(settings['pe_console'], **client_options)
  activities = PeEventForwarding::Activity.new(settings['pe_console'], **client_options)

  service_names = if settings['skip_events']
                    PeEventForwarding::Activity::SERVICE_NAMES.reject do |service|
                      settings['skip_events'].include?(service.to_s)
                    end
                  else
                    PeEventForwarding::Activity::SERVICE_NAMES
                  end

  if index.first_run?
    if settings['skip_jobs']
      data[:orchestrator] = -1
    else
      log.debug("Starting orchestrator for first run with #{index.count(:orchestrator)} event(s)")
      data[:orchestrator] = orchestrator.current_job_count(timeout)
    end
    unless settings['skip_plans']
      log.debug('Starting orchestrator plan_jobs for first run')
      # Index the checkpoint as Time.now with no processed IDs. Any plan finishing
      # strictly after this point will be collected on the next run.
      plan_index.save(last_finished: Time.now.utc.iso8601, ids: [])
    end
    service_names.each do |service|
      log.debug("Starting #{service} for first run with #{index.count(service)} event(s)")
      data[service] = activities.current_event_count(service, timeout)
    end
    settings['skip_events']&.each do |service|
      data[service.to_sym] = -1
    end
    index.save(**data)
    log.debug("First run. Recorded event count in #{index.filepath} and now exiting.")
    exit
  end

  # We mark the index with -1 for any event types that are skipped to signify that
  # they have been disabled. This is neccesary because upon re-enablement we want to
  # make sure we only re-initialize the index for the re-enabled services. This ensures
  # the other services continue as normal, and we don't pull in a large amount of events
  # that have accumulated in the interim.
  settings['skip_events']&.each do |service|
    data[service.to_sym] = -1
  end

  service_names.each do |service|
    if index.count(service) == -1
      # At this point we know the service is newly re-enabled.
      # Reinitialize the event count and exit.
      # Next run will continue as usual.
      data[service] = activities.current_event_count(service, timeout)
      index.save(**data)
      log.debug("Collection of #{service} events reenabled. First run. Recorded event count in #{index.filepath}.")
      # The index is now saved, so to ensure that the count does not get passed to any
      # processors (which should be written to check for `nil` or `-1`) we set it to nil.
      data[service] = nil
    else
      log.debug("#{service}: Starting count #{index.count(service)} event(s)")
      data[service] = activities.new_data(service, index.count(service), settings['api_page_size'], timeout)
    end
  end

  if settings['skip_jobs']
    data[:orchestrator] = -1
  elsif index.count(:orchestrator) == -1
    # At this point we know orchestrator is newly re-enabled.
    # Reinitialize the orchestrator event count and exit.
    # Next run will continue as usual.
    data[:orchestrator] = orchestrator.current_job_count(timeout)
    index.save(**data)
    log.debug("Orchestration jobs collection reenabled. First run. Recorded event count in #{index.filepath}.")
    # The index is now saved, so to ensure that the count does not get passed to any
    # processors (which should be written to check for `nil` or `-1`) we set it to nil.
    data[:orchestrator] = nil
  else
    log.debug("Orchestrator: Starting count: #{index.count(:orchestrator)}")
    data[:orchestrator] = orchestrator.new_data(index.count(:orchestrator), timeout)
  end

  if settings['skip_plans']
    # plans are explicitly disabled via settings; mark plan index accordingly
    plan_index.save(last_finished: nil, ids: [])
  elsif plan_index.last_finished.nil?
    # Re-enable plan collection. Index the checkpoint as Time.now with no processed IDs.
    # Only plans finishing after this moment will be collected — mirrors the task
    # re-enable pattern which snapshots the current count and moves on.
    plan_index.save(last_finished: Time.now.utc.iso8601, ids: [])
    log.debug("Orchestration plan_jobs collection reenabled. Recorded plan checkpoint in #{plan_index.filepath}.")
  else
    log.debug("Orchestrator plan_jobs: Indexing last finished timestamp: #{plan_index.last_finished}")
    processed_ids = plan_index.ids
    processed_ids = [] unless processed_ids.is_a?(Array)
    res = orchestrator.new_plan_data_by_finish(plan_index.last_finished, timeout, processed_ids: processed_ids)
    unless res.nil?
      # res contains 'last_finished' => max finished timestamp, and 'events' => [jobs]
      data[:orchestrator_plan] = res
      # compute ids of jobs that have the max finished timestamp so we can dedupe inclusive queries
      max_ts = res['last_finished']
      finished_jobs = (res['events'] || []).select do |j|
        orchestrator.plan_job_finished_timestamp(j).to_s == max_ts.to_s
      end
      processed_ids = finished_jobs.map { |j| j['name'].to_s }
      # persist plan index (advance last_finished and ids)
      plan_index.save(last_finished: max_ts, ids: processed_ids)
    end
  end

  combined_keys = service_names.dup
  combined_keys << :orchestrator unless settings['skip_jobs']
  combined_keys << :orchestrator_plan if data.key?(:orchestrator_plan)
  events_counts = {}
  combined_keys.each do |key|
    events_counts[key] = data[key]['events'].count if data[key].is_a?(Hash) && data[key]['events'].is_a?(Array)
    events_counts[key] = data[key].count if data[key].is_a?(Array)
  end

  if data.any? { |_k, v| !v.nil? && v != -1 }
    PeEventForwarding::Processor.find_each("#{confdir}/processors.d") do |processor|
      log.info("#{processor.name} starting with events: #{events_counts}")
      start_time = Time.now
      processor.invoke(data)
      duration = Time.now - start_time
      log.info(processor.stdout, source: processor.name) unless processor.stdout.empty?
      log.warn(processor.stderr, source: processor.name, exit_code: processor.exitcode) unless processor.stderr.empty? && processor.exitcode == 0
      log.info("#{processor.name} finished: #{duration} second(s) to complete.")
    end
  end
  index.save(**data.reject { |k, _| k == :orchestrator_plan }) if data.any? { |_k, v| !v.nil? }
  log.info("Event Forwarding total execution time: #{Time.now - common_event_start_time} second(s)")
rescue => exception
  puts exception
  puts exception.backtrace
  log.error("Caught an exception #{exception}: #{exception.backtrace}")
ensure
  lockfile.remove_lockfile
end

if $PROGRAM_NAME == __FILE__
  main(confdir, logpath, lockdir)
end
