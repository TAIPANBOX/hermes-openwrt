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
# Each scenario is bound to a check in scripts/gate-luci.sh, which installs the app into
# OpenWrt's own rootfs and asks rpcd; scripts/gate-scenarios-bound.sh asserts the binding
# both ways, and scripts/teeth-luci.sh plants a fault for each of the three checks added
# on 2026-09-24, a second one for the read permission (a file grant beside the page's
# calls), one for the free space before the first start, and three for the Providers
# page: a crafted provider name, the sign-in status, and a sign-in that is not detached,
# one for the post-upgrade script, and five for LuCI r8: the version read by running
# Hermes, a provider deleted without its key, a message not kept across the reload, an
# old message shown anyway, and a Save & Apply message kept before the apply went
# through. The last three checks run the installed pages' own
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
    # -> check_secret_never_returned

  Scenario: the page can tell a missing Telegram library from a missing token
    Given the Telegram add-on is not installed
    Then the status says the library is absent
    When the add-on's manifest appears
    Then the status says it is present
    # -> check_telegram_state_reported

  Scenario: read-only access to the page grants its own calls and nothing else
    Then the read permission holds the status and log calls and the page's UCI configuration
    And no other ubus object or method, which leaves out procd's service list
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

  Scenario: a message from long ago is not shown as news
    Given a kept message older than ten minutes
    When the page opens
    Then it is dropped, while one five minutes old, from a tab that loaded slowly in the background, is shown
    # -> check_stale_message_not_shown

  Scenario: removing the web app leaves the agent and its key alone
    When luci-app-hermes is removed
    Then its backend and menu entry are gone
    And the agent's key file is still there
    # -> check_clean_removal
