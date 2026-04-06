module PeEventForwarding
  # Simple tracker for plan job finished-timestamp and processed ids
  class PlanIndex
    attr_accessor :filepath

    def initialize(statedir)
      require 'yaml'
      @filepath = "#{statedir}/pe_event_forwarding_plan_index.yaml"
      if File.exist? @filepath
        @data = YAML.safe_load(File.read(@filepath), permitted_classes: [Symbol]) || {}
      else
        new_index_file
      end
    end

    def new_index_file
      @data = {
        'last_finished' => nil,
        'ids_at_last_finished' => [],
      }
      File.write(filepath, @data.to_yaml)
    end

    def last_finished
      # nil means disabled / not set
      @data.key?('last_finished') ? @data['last_finished'] : nil
    end

    def ids
      @data['ids_at_last_finished'] || []
    end

    def save(last_finished:, ids: [])
      @data['last_finished'] = last_finished
      @data['ids_at_last_finished'] = ids
      File.write(filepath, @data.to_yaml)
    end
  end
end
