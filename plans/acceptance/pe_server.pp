# @summary Install PE Server
#
# Install PE Server
#
# @example
#   pe_event_forwarding::acceptance::pe_server
#
# @param version
#   PE version
# @param pe_settings
#   Hash with key `password` and value of PE console password for admin user
plan pe_event_forwarding::acceptance::pe_server(
  Optional[String] $version     = '2023.8.5',
  Optional[Hash]   $pe_settings = { password => 'puppetlabsPi3!', configure_tuning => false }
) {
  # machines are not yet ready at time of installing the puppetserver, so we wait 30s
  ctrl::sleep(30)

  # identify pe server nodes
  $puppet_server = get_targets('*').filter |$n| { $n.vars['role'] == 'server' }

  # extract pe version from matrix_from_metadata_v3 output (e.g. 2023.8.0-puppet_enterprise -> 2023.8.0)
  $pe_version = regsubst($version, '-puppet_enterprise', '')

  # install PE on each server in parallel
  $futures = $puppet_server.map |$server| {
    background("set up PE on ${server.name}") || {
      # derive platform from inventory facts populated by the provisioner
      $platform = $server.facts['platform']

      $platform_tag = case $platform {
        /rhel-(\d+)/:          { "el-${1}-x86_64" }
        /redhat-(\d+)/:        { "el-${1}-x86_64" }
        /almalinux-(\d+)/:     { "el-${1}-x86_64" }
        /rocky-linux-(\d+)/:   { "el-${1}-x86_64" }
        /ubuntu-(\d\d)(\d\d)/: { "ubuntu-${1}.${2}-amd64" }
        /sles-(\d+)/:          { "sles-${1}-x86_64" }
        default: { fail("Unknown platform for PE install: ${platform}") }
      }

      $installer_url = "https://pm.puppetlabs.com/puppet-enterprise/${pe_version}/puppet-enterprise-${pe_version}-${platform_tag}.tar.gz"

      # install PE via direct tarball download — ~5min faster than using deploy_pe
      run_task(
        'pe_event_forwarding::install_pe',
        $server,
        url              => $installer_url,
        console_password => $pe_settings['password'],
      )

      run_command('puppet agent -t', $server, '_catch_errors' => true)

      # create the RBAC token for integration testing
      run_command("echo '${pe_settings['password']}' | puppet access login --username admin --lifetime 12h", $server)
    }
  }
  wait($futures)
}
