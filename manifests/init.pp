# @summary Create the required cron job and scripts for sending Puppet Events
#
# This class will create the cron job that executes the event management script.
# It also creates the event management script in the required directory.
#
# @example
#   include common_events
class common_events (
  Optional[String]                                $pe_username  = undef,
  Optional[Sensitive[String]]                     $pe_password  = undef,
  Optional[String]                                $pe_token     = undef,
  Optional[String]                                $pe_console   = 'localhost',
  Optional[String]                                $timer        = '*-*-* *:0/2',
  Optional[String]                                $log_path     = undef,
  Optional[String]                                $lock_path    = undef,
  Optional[String]                                $confdir      = "${settings::confdir}/common_events",
  Enum['DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL'] $log_level    = 'WARN',
  Enum['NONE', 'DAILY', 'WEEKLY', 'MONTHLY']      $log_rotation = 'NONE',
){

  if (
    ($pe_token == undef)
    and
    ($pe_username == undef or $pe_password == undef)
  ) {
    $authorization_failure_message = @(MESSAGE/L)
    Please set both 'pe_username' and 'pe_password' \
    if you are not using a pre generated PE authorization \
    token in the 'pe_token' parameter
    |-MESSAGE
    fail($authorization_failure_message)
  }

  # Account for the differences in running on Primary Server or Agent Node
  if $facts[pe_server_version] != undef {
    $owner              = 'pe-puppet'
    $group              = 'pe-puppet'
  }
  else {
    $owner              = 'root'
    $group              = 'root'
  }

  $logfile_basepath = common_events::base_path($settings::logdir, $log_path)
  $lockdir_basepath = common_events::base_path($settings::statedir, $lock_path)
  $conf_dirs        = [$confdir, "${logfile_basepath}/common_events", "${lockdir_basepath}/common_events", "${lockdir_basepath}/common_events/cache/", "${lockdir_basepath}/common_events/cache/state"]

  file { $conf_dirs:
    ensure => directory,
    owner  => $owner,
    group  => $group,
  }

  file { "${confdir}/api":
    ensure  => directory,
    owner   => $owner,
    group   => $group,
    recurse => 'remote',
    source  => 'puppet:///modules/common_events/api',
  }

  file { "${confdir}/util":
    ensure  => directory,
    owner   => $owner,
    group   => $group,
    recurse => 'remote',
    source  => 'puppet:///modules/common_events/util',
  }

  file { "${confdir}/events_collection.yaml":
    ensure  => file,
    owner   => $owner,
    group   => $group,
    mode    => '0640',
    require => File[$confdir],
    content => epp('common_events/events_collection.yaml'),
  }

  file { "${confdir}/collect_api_events.rb":
    ensure  => file,
    owner   => $owner,
    group   => $group,
    mode    => '0755',
    require => File[$confdir],
    source  => 'puppet:///modules/common_events/collect_api_events.rb',
  }

  file {'/etc/systemd/system/common_events.service':
    ensure  => present,
    content => epp('common_events/service.epp'),
  }

  file {'/etc/systemd/system/common_events.timer':
    ensure  => present,
    content => epp('common_events/timer.epp',
      { 'timer' => $timer }),
    require => [
      File["${confdir}/events_collection.yaml"],
      File[$conf_dirs]
    ],
  }

  service { 'common_events.timer':
    ensure  => running,
    enable  => true,
    require => File['/etc/systemd/system/common_events.timer'],
    notify  => Exec['common_events_daemon_reload'], ## Seems to work without this right now
  }

  exec { 'common_events_daemon_reload':
    command     => 'systemctl daemon-reload',
    path        => ['/bin', '/usr/bin'],
    refreshonly => true,
  }
}
