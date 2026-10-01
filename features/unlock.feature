# The agent runs without root, and a change to the router needs its owner's say-so.
#
# Provenance. No sentence below is a quote.
#
#   @decided 2026-10-01  The agent no longer runs as root. It reads the router freely;
#                        anything that changes the router goes through openwrt-mcp, which
#                        runs as root and decides. A change is allowed only after the
#                        owner unlocks it from the same Telegram chat, and the message
#                        that unlocks is removed from the chat at once and never reaches
#                        the model.
#   @decided 2026-10-01  What unlocks is the owner's choice, and both factors are
#                        optional: a PIN the owner sets, a six-digit code from an
#                        authenticator app, or both together as a second factor. Running
#                        as root without any of this stays possible, as an explicit,
#                        warned choice.
#   @measured 2026-10-01 by reading, not running: Hermes 0.21.5's pre_gateway_dispatch
#                        hook sees a message before authorisation, logging and the model,
#                        and can drop it; a message sent while a turn is running is
#                        steered into that turn without passing the hook. openwrt-mcp
#                        v0.5.0 has TOTP with replay protection, no PIN, no limit on
#                        wrong codes, no way to lock early, logs the code argument in
#                        its audit file, and keeps the rollback snapshot in /tmp.
#   @measured 2026-10-01 by reading, not running: a plugin's /unlock sent while a turn
#                        runs is neither on the busy-bypass list nor caught by the
#                        pending-command safety net, since both resolve built-in
#                        commands only (hermes_cli/commands.py resolve_command;
#                        gateway/run_turn.py), so it becomes the next turn's input.
#                        llm_request middleware can rewrite every model request, which
#                        is the second line here; the first is pre_gateway_dispatch.
#   @measured 2026-10-01 Telegram Bot API, deleteMessage: bots can delete incoming
#                        messages in private chats; in a group only as an administrator.
#
# Not bound yet: the gate that runs these (scripts/gate-unlock.sh) does not exist, so
# this file is not in gate-scenarios-bound.sh's PAIRS. It joins them in the same change
# that adds the gate, and every check named here must go red before its fix.

Feature: The agent changes the router only when its owner unlocks it

  # ---- Without root ----

  Scenario: The agent runs as its own unprivileged user
    Given hermes-agent is installed and started with the default settings
    Then the gateway and every tool process it starts run as the user hermes, not root
    And the hermes user has no password and no login shell
    # -> check_gateway_runs_as_hermes_user

  Scenario: The keys on disk stay out of the agent's reach
    Given the provider key, the Telegram token and the openwrt-mcp token are stored
    Then their files are owned by root and readable by root only
    And a command the agent runs cannot read them
    # -> check_key_files_root_only

  Scenario: The memory ceiling still holds without root
    Given mem_max_mb is set
    When the service starts
    Then the ceiling is applied by the init, which still runs as root, before the agent starts
    # -> check_memory_ceiling_non_root

  Scenario: A router upgraded from a release that ran as root keeps working
    Given a router whose data directory was written by the root-era release
    When the new release is installed over it
    Then the data directory belongs to hermes and the sessions, memory and jobs in it are kept
    # -> check_upgrade_hands_data_dir_to_hermes

  Scenario: Running as root is still possible, but only on purpose
    Given the owner sets the profile to root
    When the service starts
    Then the agent runs as root without any unlock
    And the start prints a warning that says what this allows
    # -> check_root_profile_is_opt_in_and_warned

  # ---- What needs an unlock ----

  Scenario: Reading the router needs no unlock
    Given no unlock is open
    When the agent asks openwrt-mcp for the router's state, interfaces or log
    Then it gets the answer
    # -> check_reads_need_no_unlock

  Scenario: A change while locked is refused, and the agent says how to unlock
    Given a factor is configured and no unlock is open
    When the agent tries to change the router
    Then openwrt-mcp refuses
    And the agent tells the owner to send /unlock in the private chat
    # -> check_change_refused_while_locked

  Scenario: The agent cannot unlock on its own
    Then the model is never offered openwrt-mcp's unlock or lock tools
    # -> check_unlock_tools_hidden_from_model

  Scenario: A scheduled job cannot change the router
    Given a scheduled job runs with no person present
    When it tries to change the router
    Then the change is refused even if an unlock is open at that moment
    # -> check_scheduled_job_cannot_change

  Scenario: A change that is not confirmed undoes itself, even across a reboot
    Given an unlock is open and the agent applies a configuration change
    When nobody confirms it in time, or the router reboots first
    Then the previous configuration is back
    # -> check_rollback_survives_reboot

  # ---- The factors, each optional ----

  Scenario: The owner chooses a PIN alone
    Given the factor is set to pin
    When the owner sends /unlock with the right PIN
    Then changes are allowed for the unlock window
    # -> check_pin_alone_unlocks

  Scenario: The owner chooses an app code alone
    Given the factor is set to code and the owner's phone is enrolled
    When the owner sends /unlock with the current six-digit code
    Then changes are allowed for the unlock window
    # -> check_code_alone_unlocks

  Scenario: The owner chooses both, as a second factor
    Given the factor is set to pin and code
    When the owner sends /unlock with the PIN and the current code
    Then changes are allowed for the unlock window
    But a right PIN with a wrong code, or the reverse, unlocks nothing
    # -> check_pin_and_code_both_required

  Scenario: With no factor set, nothing can change until the owner sets one
    Given hermes-agent was just installed and no factor is configured
    When the agent tries to change the router
    Then the change is refused and the agent says a factor has to be set up in LuCI first
    # -> check_no_factor_means_no_changes

  Scenario: The PIN is never stored as itself
    When the owner sets a PIN
    Then the router keeps only a slow salted hash of it, in a root-only file
    # -> check_pin_stored_as_slow_hash

  Scenario: Guessing is stopped
    When five wrong attempts arrive in a row
    Then unlocking is refused for fifteen minutes, even with the right PIN and code
    And the owner is told in the chat
    # -> check_wrong_attempts_lock_out

  Scenario: A code works once
    Given a code has unlocked once
    When the same code is sent again
    Then it is refused
    # -> check_code_works_once

  Scenario: An unlock ends by itself
    Given an unlock was opened with a window of fifteen minutes
    When fifteen minutes pass
    Then changes are refused again
    # -> check_unlock_window_ends

  Scenario: The owner can lock at once
    Given an unlock is open
    When the owner sends /lock
    Then changes are refused from that moment
    # -> check_lock_closes_at_once

  # ---- The unlock message itself ----

  Scenario: The unlock message disappears and never reaches the model
    When the owner sends /unlock with a PIN or code in the private chat
    Then the bot deletes that message from the chat
    And the message is not passed to the model or written to the conversation
    And the bot answers only whether the unlock opened and until when
    # -> check_unlock_message_deleted_and_never_reaches_model

  Scenario: An unlock sent while the agent is busy still never reaches the model
    Given the agent is in the middle of answering
    When the owner sends /unlock with a PIN or code
    Then every request to the model has that text removed before it is sent
    And nothing unlocks, and the bot asks for /unlock again once it has answered
    # -> check_unlock_while_busy_never_reaches_model

  Scenario: A bare code is treated as an unlock attempt
    Given a factor is configured
    When the owner sends a message that is only a PIN or a code, without /unlock
    Then it is handled exactly as /unlock, not passed to the model
    # -> check_bare_code_is_an_unlock_attempt

  Scenario: Nothing secret lands in a log
    Given the gateway logs at its most verbose level
    When the owner unlocks with a PIN and a code
    Then neither appears in the gateway, agent or openwrt-mcp logs, nor in openwrt-mcp's audit file
    # -> check_secret_in_no_log

  Scenario: Unlocking in a group chat is refused
    When /unlock is sent in a group
    Then nothing unlocks
    And the bot asks for the private chat, where it can delete the message
    # -> check_unlock_refused_in_group

  Scenario: An unlock opens changes for one agent only
    Given two agents on the router, each with its own name in openwrt-mcp
    When the owner unlocks from the chat of the first
    Then the first may change the router and the second is still refused
    # -> check_unlock_is_per_agent

  Scenario: Only a person the bot answers can try
    When someone outside the allowlist sends /unlock
    Then nothing is checked, nothing unlocks, and no attempt is counted against the owner
    # -> check_unlock_only_from_allowlist

  # ---- Setting it up ----

  Scenario: The owner enrols a phone from the browser
    Given the owner is signed in to LuCI
    When they open Services -> Hermes Agent -> Security and choose to add a phone
    Then a QR code is shown once, to scan with an authenticator app
    And the first code from the app must be entered before the factor is switched on
    # -> check_luci_enrol_shows_qr_and_verifies

  Scenario: The owner enrols a phone over SSH
    When the owner runs the enrol command on the router
    Then the QR code is printed in the terminal
    # -> check_cli_enrol_prints_qr

  Scenario: The PIN field is write-only
    When the owner sets a PIN in LuCI
    Then the page can say a PIN is set, and nothing can read it back
    # -> check_luci_pin_write_only
