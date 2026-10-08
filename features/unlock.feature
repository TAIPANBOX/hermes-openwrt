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
#   @measured 2026-10-02 by ONLY=check_unlock_while_busy_never_reaches_model ./scripts/gate-unlock.sh,
#                        which runs the real gateway in the 25.12 rootfs against stand-ins:
#                        the reading above was incomplete in two ways. A message queued while
#                        a turn runs is handed to pre_gateway_dispatch when its turn comes, and
#                        a Telegram-native handler a plugin registers (register_telegram_handler)
#                        runs before the adapter's own, busy or not. The plugin takes /unlock
#                        there, so an unlock sent while the agent is busy is deleted and works
#                        like any other; the request-level scrub stays as the last line for what
#                        no earlier line can know is an unlock (a PIN alone on a line of a longer
#                        message). That is why the scenario below no longer says nothing unlocks.
#
#   @decided 2026-10-01  Setup happens once: in LuCI, with a QR code to scan, or over SSH, with
#                        the QR code in the terminal. The first code from the app has to be
#                        entered before the factor is switched on. The PIN field is write-only.
#   @measured 2026-10-02 by LUCI=luci-app-hermes-0.19.0-r12.apk ONLY="check_luci_enrol_shows_qr_and_verifies
#                        check_cli_enrol_prints_qr check_luci_pin_write_only" ./scripts/gate-unlock.sh,
#                        which is luci-app-hermes before the Security page existed: all three red, on a ubus
#                        "Method not found" for the first and third and, for the second, on
#                        the README not giving the commands. Green on r13.
#
#   @measured 2026-10-02 in a QEMU OpenWrt 25.12.5 (armsr) with no /srv, where the init's
#                        mkdir -p made /srv closed to everyone but root, so the agent's user
#                        could not enter it on the way to its own data directory and the
#                        start was refused as "cannot write". The test routers and the gate's
#                        images already had a /srv that anyone may enter, which is why nothing
#                        caught it. Two scenarios under "Without root" are about that.
#   @measured 2026-10-02 on a Brume 2, through Telegram: after a successful /unlock the agent
#                        went on answering "send /unlock" from the conversation, because the
#                        unlock message is, by design, never shown to it. The two scenarios
#                        under "The unlock message itself" that end "the agent is told" are
#                        about that; what the agent is told never includes a PIN or a code.
#
#   @claude 2026-10-08   reported by a test run, not measured here: an agent on a Beryl AX could
#                        not set up a guest Wi-Fi, because the package granted it no read of
#                        wireless and only named sections of network, which hold the Wi-Fi keys
#                        and a WireGuard private key that would reach the model provider. From
#                        openwrt-mcp 0.5.0.2 every uci_get answer has each secret option replaced
#                        by '<redacted>' and `status` says so (uci_get_redacts_credentials). The
#                        three scenarios after "No tool that answers with a private key" are the
#                        r11 answer: wireless and the whole of network are read only from a daemon
#                        that says it redacts, and from nothing else.
#   @decided 2026-10-08  What an unlock window is for: in it the agent may change settings, the VPN
#                        and services; it may never run arbitrary commands, install anything from a
#                        link, or run a sysupgrade. The scenario after "No tool that answers with a
#                        private key" is that scope; a reboot is left out too, since it cannot be
#                        rolled back (a conservative reading, not part of the decision).
#
# Bound to scripts/gate-unlock.sh, and in gate-scenarios-bound.sh's PAIRS, since the change
# that added that gate. Every check there went red against the unchanged package before its
# fix. A scenario whose check is not built yet is listed by the gate as NOT IMPLEMENTED and
# fails, so a green run can only mean all of it is proven; none is left.

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

  Scenario: A router with no /srv still starts the agent
    Given a router on which /srv does not exist yet
    When the service starts for the first time, as a boot does, with a umask that closes new directories to everyone but root
    Then /srv is created so that anyone may enter it, and the data directory inside it belongs to hermes and is closed to everyone else
    And the gateway runs as hermes
    # -> check_fresh_router_without_srv_starts

  Scenario: A directory above the data directory that the agent cannot enter is named
    Given /srv already exists and only root may enter it
    When the service starts
    Then the start is refused with a message that names /srv and its mode
    And /srv is left as it was
    And once /srv is opened the same configuration starts
    # -> check_unreachable_parent_is_named

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
    When the agent does not confirm it in time (the change cut the router off, or the agent never
      got to it), or the router reboots first
    Then the previous configuration is back
    # -> check_rollback_survives_reboot

  Scenario: No tool that answers with a private key is granted by default
    Given a factor is configured, so the package writes its change policy
    Then that policy does not grant wg_new_client, whose answer is a WireGuard private key
    And a call to it is refused even while the owner has unlocked changes
    # -> check_change_policy_hands_out_no_private_key

  Scenario: An open window changes settings, the VPN and services, and never runs a command
    Given a factor is configured and the owner has unlocked changes
    When the agent asks over ubus to run a command or write a file through rpcd, flash or check a firmware,
      reboot, set a UCI option around uci_apply, define a procd service or touch packages
    Then each is refused before it reaches ubus
    And a uci_apply that creates a firewall include is refused, with nothing of its batch applied
    And restarting a service, reloading the network and a uci_apply with its rollback still work
    # -> check_window_changes_settings_never_runs_commands

  Scenario: An open window cannot reach the agent's own configuration
    Given a factor is configured and the owner has unlocked changes
    When the agent applies a change to its own settings (the profile to root), to openwrt-mcp's
      policies, or to rpcd, dropbear, uhttpd or the mounts
    Then each is refused for want of a scope, and none of those files changes
    And a WireGuard interface and a firewall zone are still applied, with the rollback armed
    # -> check_window_cannot_reach_the_agents_own_config

  Scenario: No change policy from an openwrt-mcp that does not refuse a setting that runs code
    Given a factor is configured
    And the openwrt-mcp installed does not report that uci_apply refuses code execution, as one before 0.5.0.3
    When the service starts
    Then no change policy is written, and the start says why in one line
    And after an unlock a uci_apply is still refused, for want of a policy
    # -> check_no_change_policy_without_code_exec_refusal

  Scenario: The agent can read the Wi-Fi and the whole network, and never their keys
    Given the router's wireless configuration holds a Wi-Fi key and its network a WireGuard private key
    And the openwrt-mcp installed reports that uci_get redacts credentials
    When the agent reads wireless, or the whole of network, or the private key alone, with no unlock
    Then it gets the settings, and every key in them reads '<redacted>', never the key itself
    And netifd's wireless status, which carries the same key unredacted, is still refused
    # -> check_wireless_and_network_reads_are_redacted

  Scenario: No wide read from an openwrt-mcp that does not say it redacts
    Given the openwrt-mcp installed does not report that uci_get redacts credentials, as one before 0.5.0.2
    When the service starts
    Then the agent is granted system, dhcp, firewall and the named network sections only, as before
    And the start says why in one line
    And a read of wireless or of the whole network is refused
    # -> check_wide_reads_only_from_a_daemon_that_redacts

  Scenario: A daemon left running from before an upgrade gets no wide read
    Given openwrt-mcp was upgraded, and the daemon still serving is the older version
    And restarting it does not change that
    When the service starts
    Then the agent is granted the narrow reads only, and the start names the version that is running
    And with a daemon at the installed version the same start grants wireless and the whole of network
    # -> check_daemon_from_before_the_upgrade_gets_no_wide_reads

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
    Then the bot deletes it and answers as at any other time, and the agent never sees it
    And a PIN on a line of its own inside a longer message, which no earlier line takes, is removed from every request to the model before it is sent
    # -> check_unlock_while_busy_never_reaches_model

  Scenario: A message edited into an unlock is handled the same way
    Given the owner sent an ordinary message
    When they edit it into /unlock with a PIN
    Then the edited message is deleted from the chat
    And the PIN reaches neither the model nor any file on the router
    # -> check_edited_unlock_never_reaches_model

  Scenario: A bare code is treated as an unlock attempt
    Given a factor is configured
    When the owner sends a message that is only a PIN or a code, without /unlock
    Then it is handled exactly as /unlock, not passed to the model
    # -> check_bare_code_is_an_unlock_attempt

  Scenario: After an unlock the agent is told the window is open, and never the PIN
    Given the owner unlocked in the chat
    When the owner then sends the agent a message
    Then the request to the model carries one line saying the owner has unlocked changes until a time, and that a change which was waiting should be done now
    And no request to the model holds the PIN or a code
    When the owner sends /lock, or is locked out by wrong tries
    Then no later request carries that line, not even in the conversation it replays
    And a scheduled job is not told the window is open, since it may not change the router in it
    # -> check_agent_told_window_is_open

  Scenario: When the window ends by itself the agent is no longer told it is open
    Given the owner unlocked and the agent was told
    When the window runs out with nobody sending /lock
    Then the next request to the model carries no such line
    # -> check_agent_not_told_after_window_ends

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
    And the config file the package ships gives the same two steps as the README, pending first and then activate
    # -> check_cli_enrol_prints_qr

  Scenario: The PIN field is write-only
    When the owner sets a PIN in LuCI
    Then the page can say a PIN is set, and nothing can read it back
    # -> check_luci_pin_write_only
