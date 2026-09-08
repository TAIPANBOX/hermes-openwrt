# The Telegram platform package.
#
# Provenance. Yurii asked for this in one line, on 2026-09-08: "Роби пакет для Telegram".
# That is the whole of his stated requirement, so the scenarios below are NOT quotes from
# him and must not be read as any. They are derived from two sources that can be checked:
#
#   @measured  pip dry-run inside openwrt/rootfs aarch64_generic on 25.12.4 and 24.10.8,
#              2026-09-08. Adding python-telegram-bot[webhooks]==22.6 to the router
#              profile adds exactly two distributions, python-telegram-bot 22.6 and
#              tornado 6.5.8, and changes the version of nothing already installed.
#   @claude    upstream's own plugins/platforms/telegram/plugin.yaml, which declares
#              TELEGRAM_BOT_TOKEN as required and password-typed, and TELEGRAM_ALLOWED_USERS
#              as the allowlist; and gateway/authz_mixin.py, whose documented order ends
#              "5. Default: deny".
#
# Each scenario is bound to a named check in scripts/gate-telegram.sh. The binding is
# asserted both ways by scripts/gate-scenarios-bound.sh: no scenario without a check, and
# no check claiming a scenario that is not here.

Feature: Telegram reaches the agent on the router

  Background:
    Given a router running OpenWrt with hermes-agent installed

  # Why an add-on package at all, rather than folding the library into the base.
  # The platform's CODE already ships in the base package; only the library is absent.
  Scenario: the base package alone cannot talk to Telegram
    Given only hermes-agent is installed
    When the packaged interpreter imports telegram
    Then the import fails
    And the telegram platform code is nevertheless already present
    # -> check_base_lacks_the_library

  Scenario: the add-on adds only what the base does not already have
    When hermes-agent-telegram is installed alongside hermes-agent
    Then no file it owns is also owned by hermes-agent
    And the package manager reports no conflict
    # -> check_no_file_collision

  Scenario: the library works on the router's own interpreter
    Given hermes-agent-telegram is installed
    When the packaged interpreter imports telegram and telegram.ext
    Then both import
    And the version is 22.6
    # -> check_library_imports

  # The three refusals. A router logs to a screen nobody reads, so each one names the
  # single thing to fix instead of flapping.
  Scenario: enabling Telegram without the library says which package to install
    Given hermes-agent-telegram is NOT installed
    And the telegram platform is enabled in /etc/config/hermes
    When the service starts
    Then it refuses
    And the message names hermes-agent-telegram
    # -> check_refuses_without_library

  Scenario: enabling Telegram without a token says where to write it
    Given the telegram platform is enabled
    And the token file is absent
    When the service starts
    Then it refuses
    And the message names the token file
    # -> check_refuses_without_token

  Scenario: a token with nobody allowed is refused rather than left open
    Given the telegram platform is enabled and a token is present
    And no user id is allowed and allow_all is not set
    When the service starts
    Then it refuses
    And the message says how to allow a user
    # -> check_refuses_without_allowlist

  Scenario: the token reaches the process without passing through anything readable
    Given a token is written through the LuCI RPC
    When the service runs
    Then the token is in the process environment
    And it appears in no command line
    And uci show prints no part of it
    And the file holding it is 0600 root
    # -> check_token_never_readable

  Scenario: removing the add-on leaves a working base
    Given both packages are installed
    When hermes-agent-telegram is removed
    Then no file of it remains
    And hermes-agent still runs
    # -> check_removal_is_clean
