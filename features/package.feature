# The package's own life on a router: install, start, keep its keys out of sight, survive a
# reinstall and an upgrade, leave cleanly.
#
# Provenance. No sentence below is a quote.
#
#   @decided 2026-10-05  An upgrade leaves the service's start at boot as the owner set it: a
#                        router whose owner switched it off keeps it off after apk upgrade.
#   @measured 2026-10-05 on a Brume 2 upgrading from the feed (0.21.5-r5 to r6): the start at
#                        boot was off before the upgrade and on after it, because post-upgrade
#                        ran the same enable as post-install. OpenWrt's own default_postinst
#                        enables a service on install and not on upgrade (PKG_UPGRADE=1).
#   @claude 2026-10-05   Scenarios 1 to 11 describe what scripts/gate-package.sh has checked
#                        since before this file existed, written down so that gate binds both
#                        ways like every other; they paraphrase the gate's own comments.
#
# Bound to scripts/gate-package.sh by scripts/gate-scenarios-bound.sh, both ways;
# scripts/teeth.sh proves the gate can fail.

Feature: The package installs, runs, keeps its keys out of sight, and leaves cleanly

  Scenario: it installs on OpenWrt 25.12
    Given a bare OpenWrt 25.12 rootfs
    When the package is installed with apk
    Then apk registers it
    # -> check_installs

  Scenario: every dependency it declares comes from the release's own feed
    Given the package installed
    Then python3, pip, the CA bundle, bash, ffmpeg, ffprobe, ripgrep and openwrt-mcp are all there
    # -> check_deps_resolve

  Scenario: the command line runs on the router
    Given the package installed
    When hermes --version is run
    Then it prints the Hermes Agent version
    # -> check_cli_runs

  Scenario: it ships disabled and says so
    Given the package just installed, with nothing configured
    Then the start at boot is switched on
    And starting it says it is disabled in /etc/config/hermes, and nothing runs
    # -> check_ships_disabled

  Scenario: it refuses to start without a key, naming the fix
    Given the service enabled in UCI and no provider key
    When it is started
    Then it refuses and says where the key goes
    # -> check_refuses_without_key

  Scenario: the command the init hands procd actually starts and stays up
    Given a key and a configuration
    When the command and environment the init builds for procd are run
    Then the gateway starts and is still running thirty seconds later
    # -> check_service_command_runs

  Scenario: the key never reaches a command line
    Given a key in the provider key file
    Then the command the init hands procd carries the key's path, not the key
    And the gateway that command starts does not have the key on its command line
    # -> check_key_not_in_argv

  Scenario: the key never reaches UCI
    Given the service started with a key
    Then the key is nowhere in the hermes UCI configuration
    # -> check_key_not_in_uci

  Scenario: the key never reaches procd's own service table
    Given the environment the init hands procd
    Then the key is not in it, so ubus call service list cannot show it
    # -> check_key_not_in_procd_env

  Scenario: a configuration edited by hand survives a reinstall
    Given /etc/config/hermes changed by hand
    When the package is removed and installed again
    Then the change is still there, and the package's own files were written again
    # -> check_config_survives

  Scenario: removal is clean and keeps the account
    When the package is removed
    Then its programs, its site-packages and its start at boot are gone
    And the hermes user and group stay, with the same id
    And installing it again finds that account and makes no second one
    # -> check_clean_removal

  Scenario: an upgrade leaves the start at boot as the owner set it
    Given the owner has switched the service's start at boot off
    When the package is upgraded
    Then the start at boot is still off
    And a start at boot that was on is still on after an upgrade
    # -> check_upgrade_keeps_boot_start
