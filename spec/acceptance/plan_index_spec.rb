require 'spec_helper_acceptance'
require 'yaml'

describe 'plan index file' do
  before(:all) do
    set_sitepp_content(declare('class', 'pe_event_forwarding', { 'pe_token' => auth_token, 'disabled' => true, 'log_level' => 'DEBUG' }))
    trigger_puppet_run(puppetserver)
    puppetserver.run_shell("#{CONFDIR}/pe_event_forwarding/collect_api_events.rb")
  end

  after(:all) do
    set_sitepp_content(declare('class', 'pe_event_forwarding', { 'pe_token' => auth_token, 'disabled' => true, 'log_level' => 'DEBUG' }))
    trigger_puppet_run(puppetserver)
  end

  it 'plan index file exists after first run' do
    expect(puppetserver.file_exists?("#{CONFDIR}/pe_event_forwarding/pe_event_forwarding_plan_index.yaml")).to be true
  end

  it 'contains expected keys' do
    index = get_plan_index
    expect(index.keys).to include('last_finished', 'ids_at_last_finished')
  end

  it 'advances last_finished and populates ids after a plan job completes' do
    initial_ts = get_plan_index['last_finished']
    puppetserver.run_shell("LC_ALL=en_US.UTF-8 puppet plan run facts targets=#{console_host_fqdn}")
    puppetserver.run_shell("#{CONFDIR}/pe_event_forwarding/collect_api_events.rb")
    updated = get_plan_index
    expect(updated['last_finished']).not_to eq(initial_ts)
    expect(updated['ids_at_last_finished']).not_to be_empty
  end

  describe 'skip_plans behavior' do
    it 'when skip_plans is true, plan index last_finished is nil' do
      disable_plan_collection
      puppetserver.run_shell("#{CONFDIR}/pe_event_forwarding/collect_api_events.rb")
      index = get_plan_index
      expect(index['last_finished']).to be_nil
    end

    it 'when plan collection is re-enabled, last_finished is set to a non-nil value' do
      enable_plan_collection
      puppetserver.run_shell("#{CONFDIR}/pe_event_forwarding/collect_api_events.rb")
      index = get_plan_index
      expect(index['last_finished']).not_to be_nil
    end
  end
end
