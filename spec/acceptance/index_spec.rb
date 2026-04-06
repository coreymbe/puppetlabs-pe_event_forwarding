require 'spec_helper_acceptance'
require 'yaml'

describe 'index file' do
  before(:all) do
    TARGET_SERVER.run_shell("#{CONFDIR}/pe_event_forwarding/collect_api_events.rb")
  end

  it 'index file exists' do
    expect(TARGET_SERVER.file_exists?("#{CONFDIR}/pe_event_forwarding/pe_event_forwarding_indexes.yaml")).to be true
  end

  it 'writes expected keys' do
    index_contents = TARGET_SERVER.run_shell("cat #{CONFDIR}/pe_event_forwarding/pe_event_forwarding_indexes.yaml").stdout
    index = YAML.safe_load(index_contents, permitted_classes: [Symbol])
    [:classifier, :rbac, :'pe-console', :'code-manager', :orchestrator].each do |key|
      expect(index.keys.include?(key)).to be true
    end
  end

  it 'treats run as the first when first_run failed' do
    index_fail_reset
    first_run_count = TARGET_SERVER.run_shell("grep 'first run' #{LOGDIR}/pe_event_forwarding.log -c", expect_failures: true).stdout.to_i
    expect(first_run_count).to eq(7)
  end

  it 'updates orchestrator index value' do
    index_contents = TARGET_SERVER.run_shell("cat #{CONFDIR}/pe_event_forwarding/pe_event_forwarding_indexes.yaml").stdout
    index          = YAML.safe_load(index_contents, permitted_classes: [Symbol])
    current_value  = index[:orchestrator]
    TARGET_SERVER.run_shell("LC_ALL=en_US.UTF-8 puppet task run facts --nodes #{console_host_fqdn}")
    index_contents = TARGET_SERVER.run_shell("#{CONFDIR}/pe_event_forwarding/collect_api_events.rb ; cat #{CONFDIR}/pe_event_forwarding/pe_event_forwarding_indexes.yaml").stdout
    index = YAML.safe_load(index_contents, permitted_classes: [Symbol])
    updated_value = index[:orchestrator]
    expect(updated_value).to eql(current_value + 1)
  end

  it 'when skip_events is undefined (default), rbac index updates' do
    current_value = get_service_index(:rbac)
    upload_rbac_script
    TARGET_SERVER.run_shell("#{CONFDIR}/pe_event_forwarding/generate_rbac_event.rb --create")
    TARGET_SERVER.run_shell("#{CONFDIR}/pe_event_forwarding/collect_api_events.rb")
    updated_value = get_service_index(:rbac)
    expect(updated_value).to eql(current_value + 1)
  end

  it 'when skip_events includes rbac, index does NOT update' do
    disable_rbac_events
    TARGET_SERVER.run_shell("#{CONFDIR}/pe_event_forwarding/generate_rbac_event.rb --update")
    TARGET_SERVER.run_shell("#{CONFDIR}/pe_event_forwarding/collect_api_events.rb")
    updated_value = get_service_index(:rbac)
    expect(updated_value).to be(-1)
  end

  it 'when rbac events are re-enabled, rbac index updates' do
    enable_rbac_events
    original_rbac_index = get_service_index(:rbac)
    disable_rbac_events
    TARGET_SERVER.run_shell("#{CONFDIR}/pe_event_forwarding/generate_rbac_event.rb --update --email pie-team@example.com")
    TARGET_SERVER.run_shell("#{CONFDIR}/pe_event_forwarding/collect_api_events.rb")
    enable_rbac_events
    TARGET_SERVER.run_shell("#{CONFDIR}/pe_event_forwarding/collect_api_events.rb")
    updated_rbac_index = get_service_index(:rbac)
    expect(updated_rbac_index).to eql(original_rbac_index + 1)
  end
end
