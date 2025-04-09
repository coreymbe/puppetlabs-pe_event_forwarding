require 'puppet_litmus'

# The Target class and TargetHelpers module are a useful ways
# for tests to reuse Litmus' helpers when they want to do stuff
# on nodes that may not be the current target host (like e.g.
# the master or the ServiceNow instance).
#
# NOTE: The code here is Litmus' recommended approach for multi-node
# testing (see https://github.com/puppetlabs/puppet_litmus/issues/72).
# We should revisit it once Litmus has a standardized pattern for
# multi-node testing.

class Target
  include PuppetLitmus

  attr_reader :uri

  def initialize(uri)
    @uri = uri
  end

  def bolt_config
    inventory_hash = LitmusHelpers.inventory_hash_from_inventory_file
    LitmusHelpers.config_from_node(inventory_hash, @uri)
  end

  # Make sure that ENV['TARGET_HOST'] is set to uri
  # before each PuppetLitmus method call. This makes it
  # so if we have an array of targets, say 'agents', then
  # code like agents.each { |agent| agent.bolt_upload_file(...) }
  # will work as expected. Otherwise if we do this in, say, the
  # constructor, then the code will only work for the agent that
  # most recently set the TARGET_HOST variable.
  PuppetLitmus.instance_methods.each do |name|
    m = PuppetLitmus.instance_method(name)
    define_method(name) do |*args, **kwargs, &block|
      ENV['TARGET_HOST'] = uri
      m.bind(self).call(*args, **kwargs, &block)
    end
  end

  def file_exists?(file_path)
    ENV['TARGET_HOST'] = uri
    command = "test -f #{file_path} && echo 'true'"
    result = run_shell(command, expect_failures: true).stdout
    result.include?('true')
  end

  def directory_exists?(file_path)
    ENV['TARGET_HOST'] = uri
    command = "test -d #{file_path} && echo 'true'"
    result = run_shell(command, expect_failures: true).stdout
    result.include?('true')
  end
end

class TargetNotFoundError < StandardError; end

module TargetHelpers
  def puppetserver
    target('puppetserver', 'acceptance:provision_vms', 'server')
  end
  module_function :puppetserver

  def localhost
    target('localhost', 'acceptance:provision_vms', 'localhost')
  end

  def target(name, setup_task, role)
    @targets ||= {}

    unless @targets[name]
      # Find the target
      inventory_hash = LitmusHelpers.inventory_hash_from_inventory_file
      targets = LitmusHelpers.find_targets(inventory_hash, nil)
      target_uri = targets.find do |target|
        vars = LitmusHelpers.vars_from_node(inventory_hash, target) || {}
        (vars['role'] || []) == role
      end
      unless target_uri
        raise TargetNotFoundError, "none of the targets in 'inventory.yaml' have the '#{role}' role set. Did you forget to run 'rake #{setup_task}'?"
      end
      @targets[name] = Target.new(target_uri)
    end

    @targets[name]
  end
  module_function :target
end

module LitmusHelpers
  extend PuppetLitmus
end
