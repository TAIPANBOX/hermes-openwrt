# The web interface: Services -> Hermes Agent.
#
# Provenance. No sentence below is a quote.
#
#   @claude 2026-09-08   The design this file holds the page to: keys are write-only. The
#                        page can store a key and can ask whether one is present, and no
#                        method returns one.
#   @measured 2026-09-21 against b39861b, with OpenWrt's own procd serializer: the Telegram
#                        and MCP tokens sat in the service's environment, and this app's
#                        read permission granted procd's service list, which returns it.
#   @claude 2026-09-21   From source review: the page wrote fixed key files while the
#                        service read the paths set in UCI, and a failed write was reported
#                        as stored.
#   @measured 2026-09-24 against a8831f4, scripts/gate-luci.sh red before the fix on the
#                        three checks added for those.
#   @claude 2026-09-24   From review: check_read_acl_is_narrow read two keys of the read
#                        block and no others, so a file grant beside them would have passed.
#   @measured 2026-09-25 on a Flint 2 and a Brume 2, right after a clean install by README:
#                        `ubus call hermes status` gave free_kb 0, because the data directory
#                        is created at the first start and df on the missing path failed.
#   @claude 2026-09-25   From overview.js: with 0 the page shows 0 B and the warning that
#                        less than 256 MB is free, while both routers had 6.5 GB.
#   @decided 2026-09-25  A Providers page: further providers with write-only keys, and
#                        ChatGPT sign-in and sign-out from the page.
#   @measured 2026-09-25 on a Flint 2 and a Brume 2, r6 upgraded to r7 by apk: ubus listed
#                        only the old methods until rpcd was restarted by hand, because apk
#                        runs post-install on an install and post-upgrade on an upgrade.
#   @measured 2026-09-25 on a Brume 2, the Providers page in a browser: every page took
#                        5 to 7 s to load, because status ran `hermes --version` (4 s);
#                        a deleted provider left its key file, and a provider added later
#                        under the same name showed it as stored; "Saved" and "Signed in
#                        to ChatGPT" were shown just before the page reloaded and never seen.
#   @decided 2026-09-25  All three are fixed.
#
#   @decided 2026-10-02  The Security page (LuCI r13), paraphrasing what the owner chose on
#                        2026-10-01: a phone is added once in the browser, by a QR code to scan,
#                        and the first code from the app has to be entered before the factor is
#                        switched on; the PIN field is write-only; a PIN is 4 to 8 digits; and
#                        each factor is optional and the owner's own choice.
#   @claude 2026-10-02   How that is built: the page asks the rpcd backend, which asks openwrt-mcp
#                        and keeps nothing of the PIN or the phone's secret. security_status joins
#                        the read permission, which is a deliberate change to what invariant 11
#                        grants: it answers facts and no secret. Everything that writes or returns
#                        enrolment material is write-only. Where the page is not for the owner (the
#                        root and assistant profiles), or openwrt-mcp is not answering, or the agent
#                        has never been started, it offers nothing, and the backend refuses the
#                        same calls. The scenarios about the QR, the PIN and the SSH enrolment are in
#                        features/unlock.feature, bound to scripts/gate-unlock.sh.
#   @measured 2026-10-08 on a Flint 2 and a Beryl AX, LuCI 0.21.5-r1: a factor saved on the
#                        Security page reached UCI, but the agent was not restarted and the
#                        change policy not written, in two states: reload_config's md5 file
#                        without a line for hermes (the Flint, the line deleted by hand) and a
#                        line for hermes already holding the new content's sum (the Beryl).
#   @decided 2026-10-08  What an unlock window is for, paraphrased: installing packages is allowed
#                        only from the official OpenWrt feed, and only when the owner has opted in.
#   @claude 2026-10-09   How the opt-in is set on the Security page (LuCI r3): a switch, written by
#                        set_packages (write permission), on only with a factor in force, since an
#                        install waits for an unlock like any change; security_status reports what
#                        it is set to. Whether the agent is then given apk_add is the agent's start
#                        to decide, in features/unlock.feature and features/runtime.feature.
#
# Each scenario is bound to a check in scripts/gate-luci.sh, which installs the app into
# OpenWrt's own rootfs and asks rpcd; scripts/gate-scenarios-bound.sh asserts the binding
# both ways, and scripts/teeth-luci.sh plants a fault for each of the three checks added
# on 2026-09-24, a second one for the read permission (a file grant beside the page's
# calls), one for the free space before the first start, and three for the Providers
# page: a crafted provider name, the sign-in status, and a sign-in that is not detached,
# one for the post-upgrade script, and five for LuCI r8: the version read by running
# Hermes, a provider deleted without its key, a message not kept across the reload, an
# old message shown anyway, and a Save & Apply message kept before the apply went
# through, and thirteen for LuCI r13's Security page: the status reporting a PIN that is
# not there, a factor accepted without what it needs, the commit taking another page's
# staged changes, the Security calls answering outside the owner profile, a call left out
# of the permissions, a PIN field prefilled, a PIN left in its field, the QR kept when the
# page is left, the secret kept in the tab's storage, a factor open without what it needs,
# Save sending it anyway, the page offering controls outside the owner profile, and a key
# read with jshn's loader. The checks on the pages' JavaScript run the installed pages' own
# JavaScript (scripts/test-luci-views.mjs) against a stand-in for LuCI.

Feature: The web page manages the agent and never hands a key back

  Background:
    Given hermes-agent installed on OpenWrt 25.12 with luci-base and rpcd

  Scenario: the web app installs next to the agent
    When luci-app-hermes is installed
    Then the package manager registers it
    # -> check_installs

  Scenario: its files land where LuCI looks for them
    Then both views, the menu entry, the permissions and the rpcd backend are in place
    And the backend is executable
    # -> check_files_land

  Scenario: the menu and the permissions are valid JSON
    Then both parse
    # -> check_json_valid

  Scenario: both views parse as JavaScript
    Then the overview and the settings view pass a syntax check
    # -> check_js_parses

  Scenario: the backend appears on ubus
    When rpcd starts
    Then it registers the hermes object
    # -> check_ubus_object

  Scenario: the status call answers what the overview shows
    When the page asks for status
    Then the reply has running, enabled, version, data directory, free space and whether a key is set
    # -> check_status_answers

  Scenario: the page's status does not start the agent to learn its version
    When a page asks for the status
    Then the version is the one recorded on disk for the installed agent
    And /usr/bin/hermes is not run, so the answer comes at once and nothing asks the network
    # -> check_status_reads_version_from_disk

  Scenario: before the first start the page shows the free space where the data will go
    Given the agent is installed and its data directory is not created yet
    When the page asks for the status
    Then the free space is that of the nearest directory that exists, not zero
    And an empty data directory setting means the directory the service uses
    And asking does not create the directory
    # -> check_free_space_before_first_start

  Scenario: a key written through the page lands readable by root only
    When a key with stray spaces is written through the page
    Then the file holds the trimmed key
    And only root can read it
    # -> check_secret_written_0600

  Scenario: no method gives a key back
    Given a key was written through the page
    When every method the page can read is called
    Then none of the replies contains the key
    And the status still says a key is present
    And no program the backend runs while it writes a key is given the key, in its arguments or in its environment
    # -> check_secret_never_returned

  Scenario: the page can tell a missing Telegram library from a missing token
    Given the Telegram add-on is not installed
    Then the status says the library is absent
    When the add-on's manifest appears
    Then the status says it is present
    # -> check_telegram_state_reported

  Scenario: read-only access to the page grants its own calls and nothing else
    Then the read permission holds the status and log calls, the Security page's status call, and the page's UCI configuration
    And no other ubus object or method, which leaves out procd's service list and every call that writes a PIN or returns enrolment material
    And no file access and no other scope
    # -> check_read_acl_is_narrow

  Scenario: a key that could not be written is reported as not saved
    Given the key file cannot be written
    When a key is written through the page
    Then the reply says it failed
    And it does not say the key is stored
    # -> check_secret_write_failure_reported

  Scenario: when the service reads a key from elsewhere, the page says so and writes nothing
    Given UCI points the service at a key file outside the page's own slot
    When a key is written through the page
    Then the reply refuses and names the file the service reads
    And the page's own slot is not written
    And the status reports whether the file the service reads holds a key
    # -> check_secret_path_mismatch_refused

  Scenario: a further provider's key goes in and does not come out
    Given a provider section on the Providers page
    When a key is typed for it, even while the section itself is being saved
    Then it lands in that provider's own root-only file, trimmed
    And the page learns only that a key is stored, and no method returns it
    # -> check_provider_key_written_0600

  Scenario: a crafted provider name writes nothing
    Given a provider name with a path in it, capitals, the name of the main key's file, or nothing at all
    When the page tries to store a key under it
    Then it is refused and no file is written anywhere
    # -> check_provider_key_name_refused

  Scenario: a provider whose key file is set elsewhere is not written from the page
    Given a provider section that points its key at another file
    When a key is typed for it
    Then the page refuses and says the page does not manage that file
    # -> check_provider_key_path_mismatch_refused

  Scenario: ChatGPT is signed in and out from the page
    Given the Providers page and a ChatGPT account that allows device code sign-in
    When the owner asks to sign in
    Then the page shows the address and the code at once, and notices when the sign-in is done
    And signing out from the page leaves the router signed out
    # -> check_chatgpt_sign_in_from_the_page

  Scenario: an upgraded page answers with its new calls at once
    Given a router with an earlier version of the web app
    When it is upgraded
    Then rpcd is restarted, as on a first install, so the page's new calls are there without a reboot
    # -> check_upgrade_restarts_rpcd

  Scenario: deleting a provider deletes its key
    Given a provider on the Providers page with a key stored
    When it is deleted
    Then its key file is cleared before the provider goes
    And a key file set elsewhere in UCI is left to the operator
    # -> check_removed_provider_takes_its_key

  Scenario: what the page says just before it reloads is there after the reload
    When Save & Apply, ChatGPT sign-in or sign-out ends in a reload
    Then the reloaded page shows the message, a failure included, once
    And after Save & Apply only once LuCI reports the apply went through, so a rolled-back apply leaves no "Saved"
    # -> check_messages_survive_the_reload

  Scenario: a Save & Apply that changes only a key still says it saved, once
    Given a page where only a key was typed, which goes past UCI, so LuCI has nothing to apply
    When Save & Apply is pressed
    Then the page says "Saved" at once, since LuCI then neither announces an apply nor reloads
    And a key that did not save is shown once, with no "Saved" beside it
    And the next Save & Apply that does change something shows "Saved" once after its reload, as does one after an apply that was rolled back
    # -> check_saved_when_only_a_key_changed

  Scenario: a message from long ago is not shown as news
    Given a kept message older than ten minutes
    When the page opens
    Then it is dropped, while one five minutes old, from a tab that loaded slowly in the background, is shown
    # -> check_stale_message_not_shown

  Scenario: saving the settings page never puts the agent back to root
    Given a router where no profile was ever chosen, so the unprivileged owner profile applies
    When the settings page is opened and saved
    Then the profile it writes is owner, the first choice offered, beside assistant and root
    And the old name admin is not offered, and a router set to admin is shown and saved as root
    # -> check_profile_field_defaults_to_owner

  # @claude 2026-11-01: the model from llm-gateway, the router's own gateway to the house's model
  # servers (hermes.main.llm_gateway, hermes-agent 0.21.5-r20), is switched on and off on this page too.
  Scenario: the settings page switches the model from llm-gateway on and off and leaves the endpoint alone
    Given the settings page's model section, with an endpoint, a model and a key stored
    When the owner turns on the switch for the model from llm-gateway and saves
    Then the switch is what is written, and the endpoint, model and key fields stay on the page and in UCI as they were
    # -> check_llm_gateway_switch_leaves_the_endpoint_alone

  Scenario: the Security page tells what is in force and never a secret
    Given the owner profile, with openwrt-mcp's client for the agent paired
    When the page asks for the security status
    Then it gets the profile, the factor in force and its window, failure limit and lockout, whether a PIN is set and whether a phone is enrolled or being added, and whether package installs are switched on
    And no other key, no PIN, no secret, no URI and no QR
    And where openwrt-mcp has no such client, or is not installed, or the factor is not one, it says so instead of guessing
    # -> check_security_status_reports_facts_only

  Scenario: the factor can only be set to what exists
    Given a router where only some of a PIN and a phone exist
    When a factor that needs what is missing is chosen, or a window, a failure limit or a lockout the router would not take
    Then the choice is refused and nothing is written, not the factor and not another page's staged changes
    And a choice that can be honoured is written, with its settings, and the agent is told its configuration changed
    And it is told exactly once, the first choice after a boot included, so the new factor is in force without a restart
    And the PIN the factor in force asks for cannot be cleared
    # -> check_security_factor_never_outruns_what_exists

  Scenario: a saved factor reaches the agent even when the router's own reload has nothing to tell
    Given the copy reload_config keeps has no line for the agent's configuration, as after a reinstall
    When the owner saves a factor on the Security page
    Then the agent is told its configuration changed, exactly once
    Given the copy reload_config keeps already matches what the agent's configuration will hold
    When the owner saves that factor
    Then the agent is told, exactly once
    And an ordinary change, which reload_config itself tells, is not told a second time
    # -> check_security_factor_announced_when_reload_cannot_tell

  Scenario: the owner opts in to package installs from the official feed only with a factor in force
    Given the owner profile, with no factor in force
    When the owner asks for package installs from the official OpenWrt feed
    Then it is refused, naming the factor, and nothing is written and nobody is told
    And any value but off or official is refused, a command or a flag included
    Given a factor in force
    When the owner asks for package installs from the official OpenWrt feed
    Then it is written without another page's staged changes, and the agent is told its configuration changed, exactly once
    And turning it off is always allowed, with or without a factor
    And a value the service would refuse to start on is reported as invalid, never as off or on
    # -> check_security_packages_written_only_with_a_factor

  Scenario: the package switch on the Security page opens only with a factor in force
    Given the Security page in the owner profile
    When no factor is in force, or the one in force cannot be satisfied
    Then the switch "Let the agent install packages from the official OpenWrt feed" cannot be turned on, and a tick made anyway sends nothing
    When a factor is in force
    Then turning it on sends official and turning it off sends off, and the page reloads to show what is set
    And left on after the factor was taken away, it can be turned off and the page says the agent is given nothing to install with
    And outside the owner profile there is no switch
    # -> check_security_packages_switch_needs_a_factor

  Scenario: the approver of high-impact changes is one of the Telegram users allowed to talk to the agent
    Given the owner profile, with Telegram on and two ids allowed
    When the owner chooses who approves from the Security page
    Then only one of the allowed ids, or none, is written, procd is told once, and anything else is refused with the file unchanged
    And the status says who approves and whether an approval could work, which needs a PIN and a phone
    And none means nobody with two ids allowed, and the one id when only one is allowed, and with Telegram off there is no choice
    # -> check_security_approver_chosen_only_from_the_allowed_ids

  Scenario: the page offers only the allowed Telegram ids as approvers and says when approving cannot work
    When the Security page shows who approves high-impact changes
    Then it offers none and the allowed ids, sends only one of those, and says so when the router refuses
    And it says that approving needs a PIN and a phone when one is missing, and that Telegram is needed when no id is allowed
    # -> check_security_approver_offered_only_from_the_allowed_ids

  Scenario: the router's own bot takes its token on standard input and binds the owner's chat by a one-time code
    Given an openwrt-mcp that reports owner_approves_past_the_listener, and the owner profile
    When the page gives a token that is not a bot token's shape
    Then it is refused and openwrt-mcp is given nothing
    When it gives a bot token
    Then openwrt-mcp holds it in a root-only file, it went to openwrt-mcp on standard input and nowhere else, and the reply holds a one-time code and never the token
    And the status says a code waits, holds neither the token nor the code, and the agent is not restarted until a chat is bound
    When the owner's chat is bound
    Then the status says the router's chat approves, and the agent is restarted once; a new code is another code, and removing the bot takes its files and restarts the agent
    And a failure of the bot reaches the status as one word of a fixed set, and one told as text, token and all, is answered as other
    # -> check_security_owner_bot_token_written_only_to_openwrt_mcp

  Scenario: the page never fills the bot's token, and shows the code to bind the chat once
    When the Security page shows the router's own bot
    Then its token field is an empty password field, a token of the wrong shape is refused without a call, and a good one is sent once and the field emptied
    And the t.me link and the code are shown, the page waits for the chat to be bound, and only then restarts the agent and reloads
    # -> check_security_owner_bot_token_never_filled_and_the_code_shown_once

  Scenario: the page offers the router's own bot only with an openwrt-mcp that has one
    When openwrt-mcp has no bot of its own
    Then the page offers nothing of it
    And with a bot bound it names the bot, says the approver choice is not used, and offers a new code and Remove; with no token it offers neither, and the bot's last failure is said in the page's own words
    # -> check_security_owner_bot_offered_only_with_a_bot_in_openwrt_mcp

  Scenario: text from the router goes into the page as text
    When every string the router's status answers holds markup, the bot's failure word among them
    Then no node of the page holds it as markup, and a failure that is not one of the bot's words is told in the page's own words for any other failure
    # -> check_security_page_puts_router_text_in_as_text

  Scenario: what the agent reaches is limited or open, and a host is what the agent can read
    Given the owner profile
    When the page sends a value that is neither limited nor open, or a host that is not host:port or [IPv6 address]:port with a real port
    Then it is refused, the refusal says what an entry looks like, and nothing is written or announced
    When it sends open and three hosts
    Then they are written, read back, and procd is told once, so the agent restarts and applies them
    And a list saved again replaces the old one, an empty one empties it, and another session's staged edit stays staged
    And a value the service would refuse is shown as one
    # -> check_security_network_limits_written_only_as_the_agent_reads_them

  Scenario: the page offers limited or open and the hosts, and says what they mean
    Given the Security page
    Then it offers limited and open, with the hosts one per line, and says what limited closes and that it does not touch the owner
    And a line the agent could not read is named and nothing is sent, and blank lines are not entries
    And open is warned about, a value the service refuses is said to be one, and a refusal is shown
    And outside the owner profile none of it is there
    # -> check_security_network_limits_offered_on_the_page

  Scenario: the failed tries on record come from openwrt-mcp, and the reset goes to it
    Given failed tries in openwrt-mcp's own record, for this client and another
    Then the package asks for openwrt-mcp 0.5.0.8 or later, the first with that record
    And the status reads this client's count
    When reset_tries is called
    Then openwrt-mcp mfa reset clears this client's and leaves the other's
    And an openwrt-mcp that keeps no count is said to and is asked for nothing, and a reset that fails is reported
    # -> check_security_failed_tries_reset_through_openwrt_mcp

  Scenario: the page shows the failed tries with a Reset, and what they cost
    Given the Security page
    Then it shows the count, says the wait grows to an hour and that a restart does not clear it, and offers Reset only with something to clear
    And a refusal is shown, a count that is not reaching the disk is said to be behind, and an openwrt-mcp with no count shows none
    And the lockout is described as the first wait, doubling up to an hour
    # -> check_security_failed_tries_shown_with_a_reset

  Scenario: a PIN alone is warned about beside the choice
    Given the Security page
    Then beside PIN it says what a PIN alone costs and what to choose instead
    And with PIN alone in force that is an alert, and with a PIN and an app code it is not
    # -> check_security_pin_alone_is_warned

  Scenario: outside the owner profile the Security calls refuse
    Given the profile is root, admin, assistant or nothing the service accepts
    When a PIN is set or cleared, a phone is added or activated, a factor is chosen, or package installs are switched
    Then each is refused, saying the owner profile only, and nothing is written
    # -> check_security_refused_outside_the_owner_profile

  Scenario: every call the Security page makes is granted, and only the facts to a reader
    Given the Security page's own source
    Then each call it makes is offered by the backend and granted by the permissions
    And the status is in the read permission and every call that writes a PIN or returns enrolment material is in the write permission alone
    And the menu opens the page behind the app's permission
    # -> check_security_page_calls_are_granted

  Scenario: the PIN fields are never filled in from the router
    Given a router that has a PIN set
    When the Security page opens
    Then it says a PIN is set and both fields are empty, and a browser is told not to fill them
    And a PIN that is typed is sent once, the fields are emptied whatever the router answers, and it is in no message and no storage
    And a PIN that is not 4 to 8 digits, or not typed twice the same, never leaves the page
    # -> check_security_pin_fields_never_prefilled

  Scenario: a PIN saved while nothing asks for it says where to choose it
    Given the owner profile with no second factor in force
    When the owner saves a PIN on the Security page
    Then after the page reloads it says the router does not ask for the PIN yet, and to choose PIN under "What unlocking asks for" and press Save there
    And it says so as a warning, without the PIN
    When a factor that asks for the PIN is already in force, or the router refused the PIN
    Then it says nothing of the kind
    # -> check_security_pin_saved_points_to_the_factor

  Scenario: the QR of a phone being added is on the page once
    When the owner asks to add a phone
    Then the page shows the QR and the secret, and asks for the current code
    And a wrong code leaves them there for another try
    And the right code, leaving the page, or Cancel takes them off the page, and they are in no message and no storage
    And asking again shows the new ones and none of the old
    # -> check_security_qr_shown_once

  Scenario: a factor whose prerequisite is missing cannot be chosen
    Given a router where a PIN, a phone being added, or both are set up
    When the factor choices are shown
    Then each choice is open only if what it needs is in force, a phone still being added counting for nothing
    And saving one that is not open sends nothing, and neither does a window, failure limit or lockout the router would not take
    And Clear PIN is open only when the factor in force does not ask for the PIN
    # -> check_security_factor_needs_its_prerequisite

  Scenario: the page offers nothing it cannot do
    Given the profile is root or assistant, or the status call fails, or openwrt-mcp does not answer, or the agent was never started
    When the Security page opens
    Then it offers no field and no button, and says why
    And in the owner profile it offers them, and says that the live unlock window cannot be shown here and that /lock in Telegram closes it
    # -> check_security_page_offers_nothing_it_cannot_do

  Scenario: removing the web app leaves the agent and its key alone
    When luci-app-hermes is removed
    Then its backend and menu entry are gone
    And the agent's key file is still there
    # -> check_clean_removal
