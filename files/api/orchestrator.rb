require_relative '../util/pe_http'
require 'time'

module PeEventForwarding
  # module Orchestrator this module provides the API specific code for accessing the orchestrator
  class Orchestrator
    attr_accessor :pe_client, :log

    def initialize(pe_console, username: nil, password: nil, token: nil, ssl_verify: true, log: nil)
      @pe_client = PeEventForwarding::PeHttp.new(pe_console, port: 8143, username: username, password: password, token: token, ssl_verify: ssl_verify, log: log)
      @log = log
    end

    def get_jobs(limit: 500, offset: 0, order: 'desc', order_by: 'name', index_count: nil, new_jobs: nil, timeout: nil)
      params = {
        limit:    [new_jobs, limit].min,
        offset:   offset,
        order:    order,
        order_by: order_by,
      }

      response_items  = []
      response        = ''
      job_counter     = 0
      total_count     = index_count + new_jobs
      loop do
        response       = pe_client.pe_get_request('orchestrator/v1/jobs', params, timeout)
        response_body  = JSON.parse(response.body)
        response_body['items']&.each { |item| response_items << item }

        job_counter += response_body['items'].empty? ? 0 : response_body['items'].count
        break if job_counter >= new_jobs
        params[:offset] = job_counter
        params[:limit] = if new_jobs - job_counter > limit
                           limit
                         else
                           new_jobs - job_counter
                         end
      end
      log&.debug("PE Get Jobs Items Found: #{response_items.count}")
      raise 'Orchestrator API request failed' unless response.code == '200'
      { 'api_total_count' => total_count, 'events' => response_items }
    end

    def run_facts_task(nodes)
      raise 'run_fact_tasks nodes param requires an array to be specified' unless nodes.is_a? Array
      body = {}
      body['environment'] = 'production'
      body['task'] = 'facts'
      body['params'] = {}
      body['scope'] = {}
      body['scope']['nodes'] = nodes

      uri = 'orchestrator/v1/command/task'
      pe_client.pe_post_request(uri, body)
    end

    def run_job(body)
      uri = '/command/task'
      pe_client.pe_post_request(uri, body)
    end

    def get_job(job_id)
      response = pe_client.pe_get_request("orchestrator/v1/jobs/#{job_id}")
      JSON.parse(response.body)
    end

    def plan_job_finished_timestamp(job)
      job['finished_timestamp']
    end

    def parse_timestamp(ts)
      return nil if ts.nil?
      # Prefer numeric values when possible (e.g. "123.456" -> 123.456).
      begin
        Float(ts)
      rescue StandardError
        begin
          Time.parse(ts).to_f
        rescue StandardError
          # Fallback to numeric conversion
          ts.to_f
        end
      end
    end

    # Fetch plan_jobs using finish timestamp filtering. Returns hash with
    # 'api_total_count' set to the max finished_timestamp seen and 'events' array.
    def get_plan_jobs_since(min_finish_timestamp:, limit: 500, offset: 0, timeout: nil)
      params = {
        limit:    limit,
        offset:   offset,
        order:    'asc',
      }
      params[:min_finish_timestamp] = min_finish_timestamp unless min_finish_timestamp.nil? || min_finish_timestamp.to_s.empty?

      response_items = []
      response = ''
      loop do
        response = pe_client.pe_get_request('orchestrator/v1/plan_jobs', params, timeout)
        response_body = JSON.parse(response.body)
        items = response_body['items'] || []
        response_items.concat(items)
        break if items.empty?
        params[:offset] = params[:offset] + items.count
      end
      raise 'Orchestrator API request failed' unless response.code == '200'
      # Filter to only finished jobs and compute max finished timestamp
      finished = response_items.select { |j| plan_job_finished_timestamp(j) }
      max_ts = finished.map { |j| plan_job_finished_timestamp(j) }.compact.max
      { 'last_finished' => max_ts, 'events' => finished }
    end

    def new_plan_data_by_finish(last_finished, timeout, processed_ids: [])
      res = get_plan_jobs_since(min_finish_timestamp: last_finished, timeout: timeout)
      events = res['events'] || []
      # If there are no finished events at or after the timestamp, nothing to do
      if events.empty?
        log&.debug('New Job Count: Orchestrator Plan: data is current')
        return nil
      end

      # Filter out already-processed job ids that match the inclusive last_finished timestamp
      if processed_ids.any?
        events.reject! do |j|
          ts = plan_job_finished_timestamp(j)
          ts.to_s == last_finished.to_s && processed_ids.include?(j['name'].to_s)
        end
      end

      # After filtering, if no events remain, nothing new
      if events.empty?
        log&.debug('New Job Count: Orchestrator Plan: data is current after dedupe')
        return nil
      end

      # Sort by finished timestamp ascending so processors get events in time order
      events.sort_by! { |j| parse_timestamp(plan_job_finished_timestamp(j)) || 0 }

      max_ts = events.map { |j| plan_job_finished_timestamp(j) }.compact.max
      log&.debug("New Plan Jobs Found: #{events.count}")
      { 'last_finished' => max_ts, 'events' => events }
    end

    def self.get_id_from_response(response)
      res = PeEventForwarding::Http.response_to_hash(response)
      res['job']['name']
    end

    def current_job_count(timeout)
      params = {
        limit:    1,
        offset:   0,
        order:    'desc',
        order_by: 'name',
      }
      response = pe_client.pe_get_request('orchestrator/v1/jobs', params, timeout)
      raise 'Orchestrator API request failed' unless response.code == '200'
      jobs = JSON.parse(response.body)
      jobs['items'].empty? ? 0 : jobs['items'][0]['name'].to_i
    end

    def new_data(last_count, timeout)
      new_job_count = current_job_count(timeout) - last_count
      if new_job_count.zero? || new_job_count.negative?
        log&.debug('New Job Count: Orchestrator: data is current')
        nil
      else
        log&.debug("New Job Count: Orchestrator: #{new_job_count}")
        get_jobs(index_count: last_count, new_jobs: new_job_count, timeout: timeout)
      end
    end
  end
end
