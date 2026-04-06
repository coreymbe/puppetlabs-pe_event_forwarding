namespace :acceptance do
  require_relative '../spec/support/acceptance/helpers'
  include TargetHelpers

  desc 'Provisions the VMs. This is currently just the server'
  task :provision_vms do
    if File.exist?('spec/fixtures/litmus_inventory.yaml')
      begin
        uri = puppetserver.first.uri
        puts("A server VM at '#{uri}' has already been set up")
        next
      rescue TargetNotFoundError
        puts 'Server VM not yet set up.'
      end
    end

    provision_list = ENV['PROVISION_LIST'] || 'acceptance'
    Rake::Task['litmus:provision_list'].invoke(provision_list)
  end

  desc 'Sets up PE on the server'
  task :setup_pe do
    include ::BoltSpec::Run
    inventory_hash = inventory_hash_from_inventory_file

    config = { 'modulepath' => File.join(Dir.pwd, 'spec', 'fixtures', 'modules') }
    params = {}
    params[:version] = ENV['PE_VERSION'] if ENV['PE_VERSION']

    bolt_result = run_plan('pe_event_forwarding::acceptance::pe_server', params, config: config, inventory: inventory_hash.clone)
    raise "setup_pe failed:\n#{JSON.pretty_generate(bolt_result)}" if bolt_result['status'] == 'failure'
  end

  desc 'Installs the module on the server'
  task :install_module do
    puppetserver.each do |server|
      Rake::Task['litmus:install_module'].reenable
      Rake::Task['litmus:install_module'].invoke(server.uri)
    end
  end

  desc 'Upload test processors'
  task :upload_processors do
    puppetserver.each do |server|
      ['proc1.sh', 'proc2.rb'].each do |processor|
        proc_path = "spec/support/acceptance/processors/#{processor}"
        folder = '/etc/puppetlabs/puppet/pe_event_forwarding/processors.d'
        server.run_shell("mkdir -p #{folder}")
        server.bolt_upload_file(proc_path, folder)
        server.run_shell("chmod +x #{folder}/#{processor}")
      end
    end
  end

  desc 'Do an agent run'
  task :agent_run do
    puppetserver.each { |server| puts server.run_shell('puppet agent -t').stdout.chomp }
  end

  desc 'Runs the tests from the local machine or CI runner'
  task :run_tests do
    rspec_command  = 'bundle exec rspec ./spec/acceptance --format documentation'
    rspec_command += ' --format RspecJunitFormatter --out rspec_junit_results.xml' if ENV['CLOUD_CI'] == 'true'
    puts("Running the tests ...\n")
    unless system(rspec_command)
      exit 1
    end
  end

  desc 'Task to run rspec tests against multiple targets'
  task :ci_run_tests do
    include ::BoltSpec::Run
    config = { 'modulepath' => File.join(Dir.pwd, 'spec', 'fixtures', 'modules') }

    puppetserver.each do |server|
      message = "Running rspec tests against #{server.uri} !"
      spec_spinner = start_spinner(message)
      params = { 'sut' => server.uri, 'format' => 'documentation' }
      bolt_result = run_task('provision::run_tests', 'localhost', params, config: config)
      stop_spinner(spec_spinner)
      if bolt_result[0]['value'].has_key?('_error')
        test_result = bolt_result[0]['value']['_error']['msg'].to_json
        puts JSON.parse(test_result)
        exit 1
      else
        test_result = bolt_result[0]['value']['result'].to_json
        puts JSON.parse(test_result)
      end
    end
  end

  desc 'Set up the test infrastructure'
  task :setup do
    tasks = [
      'spec_prep',
      'acceptance:provision_vms',
      'acceptance:setup_pe',
      'acceptance:install_module',
    ]

    tasks.each do |task|
      puts("Invoking #{task}")
      Rake::Task[task].invoke
      puts("\n")
    end
  end

  desc 'Teardown the setup'
  task :tear_down do
    puts("Tearing down the test infrastructure ...\n")
    Rake::Task['litmus:tear_down'].invoke
    FileUtils.rm_f('spec/fixtures/litmus_inventory.yaml')
  end

  desc 'Full CI pipeline: setup, run tests, tear down'
  task :ci_tests do
    begin
      Rake::Task['acceptance:setup'].invoke
      Rake::Task['acceptance:ci_run_tests'].invoke
    ensure
      Rake::Task['acceptance:tear_down'].invoke
    end
  end
end
