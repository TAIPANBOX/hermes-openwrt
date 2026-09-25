# Runtime controls of the packaged gateway.
#
# Provenance. No sentence below is a quote. The package is meant to be handed to someone
# else to install and try, and what they choose on the router has to be what the gateway
# actually runs with.
#
#   @decided 2026-09-24  The router's own configuration (UCI, edited in LuCI) is the
#                        authority for the primary model, its endpoint and the tool
#                        selection at every start, including the restarts procd makes on
#                        its own. A model switched from a chat lasts until the next start.
#   @measured 2026-09-21 against b39861b, with OpenWrt's own procd serializer and the
#                        pinned upstream resolvers in an openwrt/rootfs container: the
#                        Telegram and MCP tokens reached procd's service table; a
#                        memory-only tool selection still resolved terminal and file; a
#                        custom endpoint resolved to OpenRouter with the operator's key; no
#                        memory ceiling was serialized; the MCP settings registered no
#                        server; the configured model was not the gateway's model.
#   @measured 2026-09-24 against a8831f4, scripts/test-runtime.py red before the fix: a
#                        model persisted from a chat made the next start refuse while procd
#                        was told to retry forever; mem_max_mb=0 left an earlier ceiling in
#                        force; the kernel ceiling test passed on a limit that an earlier
#                        run in the same container had left behind.
#   @decided 2026-09-24  Two profiles, chosen in the router's settings, govern which tools
#                        the agent may use: assistant turns off terminal, code execution
#                        and file tools regardless of what the toolsets list selects; admin
#                        leaves every selected tool available, running as root as before.
#                        assistant is what applies wherever no profile is set, including on
#                        existing routers upgraded from before this option existed.
#   @decided 2026-09-24  Later the same day, superseding the default above: admin is what
#                        applies wherever no profile is set; assistant is chosen, and it
#                        tells the agent it has no terminal, code execution or file tools;
#                        one turn may make a limited number of model calls.
#   @measured 2026-09-24 through a Telegram bot on a test router, r7: in assistant, asked
#                        for the router's uptime, the model looped on the memory tool for
#                        90 calls before answering; in admin it ran uptime once and answered.
#   @measured 2026-09-24 on a Flint 2 and a Brume 2, r8 installed over the release each
#                        had, one turn each through upstream's AIAgent with the gateway's
#                        own prompt, tools and budget: with no profile set, admin ran uptime
#                        and answered in 2 model calls of 20; with max_turns=1 the turn
#                        ended at max_iterations_reached(1/1) and a call without tools
#                        summed up; in assistant the note was in the prompt, no terminal was
#                        offered, and it answered in 1 call.
#   @decided 2026-09-25  More than one provider on one router, working at the same time: a
#                        key for one, a different key for another, a ChatGPT subscription
#                        for a third. Every chat starts on the main model and can switch
#                        itself to another configured provider.
#   @measured 2026-09-25 on a Brume 2, three agents in one process started together, each
#                        asked for the router's uptime through the terminal: OpenRouter
#                        (gpt-4o-mini), Anthropic with an API key (claude-haiku-4-5) and
#                        a ChatGPT subscription (gpt-5.6-luna) all answered with the same
#                        figures while running together; 150 MB for the whole process.
#
# Each scenario is bound to a test in scripts/test-runtime.py, which gate-runtime.sh runs
# against the installed package; scripts/gate-scenarios-bound.sh asserts the binding both
# ways, and scripts/teeth-runtime.py breaks the product on purpose to prove the tests fail.

Feature: What is set on the router is what the gateway runs with

  Background:
    Given hermes-agent from this repository installed on OpenWrt

  # ---- Tools ----

  Scenario: the tools chosen in UCI are the tools the gateway gives Telegram and jobs
    Given UCI selects only the memory tools
    When the package writes the gateway's configuration
    Then upstream's own resolver gives Telegram and scheduled jobs the memory tools
    And gives them neither terminal, file nor code execution
    # -> check_gateway_selection

  Scenario: an empty tool list means no tools, not every tool
    Given UCI selects no tools at all
    When the package writes the gateway's configuration
    Then Telegram and scheduled jobs get none of terminal, file or memory
    # -> check_empty_selection

  Scenario: a misspelled tool name stops the start instead of loading the defaults
    Given UCI lists a tool name upstream does not know
    When the service starts
    Then it refuses
    # -> check_unknown_toolset_is_fatal

  Scenario: a configuration file the package cannot read stops the start and is kept
    Given the gateway's configuration is broken YAML, a list, or has a malformed tool map
    When the service starts
    Then it refuses
    And the file is exactly as it was
    # -> check_bad_yaml_is_fatal_and_preserved

  Scenario: plugins and MCP choices made by the operator survive a UCI tool change
    Given the operator enabled one plugin, disabled another and opted a platform out of MCP
    When UCI replaces the built-in tool families
    Then the enabled plugin stays enabled, the disabled one stays disabled
    And the MCP opt-out is kept
    # -> check_existing_plugin_and_mcp_selection_survives

  # ---- Profiles ----

  Scenario: the assistant profile turns off commands and file access regardless of the toolsets list
    Given UCI selects every built-in tool family, including file and terminal
    And the profile is assistant
    When the package writes the gateway's configuration
    Then upstream's own resolver gives Telegram and scheduled jobs none of terminal, process, code execution, file read, file write, patch or file search
    # -> check_assistant_profile_removes_command_and_file_tools

  Scenario: the admin profile restores them and leaves the operator's own entries alone
    Given the gateway's configuration already disables a tool of the operator's own choosing alongside terminal, file and code execution
    When the profile is admin
    Then only the operator's own choice stays disabled
    And upstream's resolver gives back terminal and file reading
    # -> check_admin_profile_restores_them_and_keeps_operator_entries

  Scenario: an empty restriction list is read as empty, the way upstream reads it
    Given the gateway's configuration has the agent section, or its restriction list, left with no value
    When the profile is assistant
    Then the start goes ahead
    And terminal, file and code execution are the restriction list
    # -> check_assistant_profile_reads_an_empty_restriction_as_empty

  Scenario: the admin profile removes the restriction list entirely once nothing is left in it
    Given the gateway's configuration disables only terminal, file and code execution, and nothing else
    When the profile is admin
    Then the restriction list is gone rather than left empty
    And an unrelated setting beside it is unchanged
    # -> check_admin_profile_removes_empty_disabled_toolsets_key

  Scenario: a restriction list that is not plain tool names stops the start instead of being guessed at
    Given the gateway's configuration names a restriction that is not a mapping, or a list of tool names that is not actually a list of names
    When either profile is applied
    Then it refuses
    And the file is exactly as it was
    # -> check_profile_refuses_non_list_disabled_toolsets

  Scenario: no profile chosen means admin, and an unrecognised one refuses to start
    Given the router's configuration names no profile at all
    When the service starts
    Then it runs in the admin profile
    When the router's configuration names a profile that is neither assistant nor admin
    Then the service refuses, naming the file and the two valid values
    And the package's own bridge refuses that same value directly, leaving the configuration untouched
    # -> check_profile_defaults_to_admin_and_refuses_unknown

  Scenario: the running gateway is put back in its chosen profile at every restart, not only the first
    Given the assistant profile has been applied once
    And a chat command or a hand edit has since re-enabled one of the tools it turns off
    When the gateway execs again, the way a respawn or an in-chat restart does
    Then the tool is turned off again
    # -> check_wrapper_reapplies_profile_at_exec

  Scenario: in the assistant profile the agent is told what it cannot do
    Given the operator's own system prompt
    When the profile is assistant
    Then the gateway's system prompt keeps the operator's text and adds that there is no terminal, code execution or file tool
    And a second start changes nothing
    When the profile is admin
    Then the operator's text is back exactly as it was
    # -> check_assistant_profile_tells_the_agent_what_it_cannot_do

  Scenario: the router's configuration sets how many model calls one turn may make
    Given the router's configuration says 20, as it does unless changed
    When the service starts
    Then the gateway's budget for one turn is 20 model calls
    And a value that is not a whole number from 1 to 500 stops the start and leaves the file alone
    # -> check_max_turns_comes_from_uci

  # ---- The configuration file itself ----

  Scenario: settings the package does not own survive, and the file stays private
    Given the gateway's configuration holds an operator model, another platform's tools and another MCP server
    When the package writes its own settings twice
    Then every operator setting is unchanged
    And the second write changes nothing
    And the file is readable by root only
    # -> check_config_preserves_other_settings

  Scenario: a configuration that is already current is left byte for byte
    Given the gateway's configuration already says what UCI says
    And it carries an operator comment and text in Ukrainian
    When the service starts again
    Then the file is not rewritten
    # -> check_config_untouched_when_already_current

  Scenario: when the file has to change, non-English text stays readable
    Given the gateway's configuration carries text in Ukrainian
    When a UCI change forces the package to rewrite it
    Then the text is written as it was typed, not as escape codes
    # -> check_config_rewrite_keeps_unicode_readable

  # ---- The router MCP connection ----

  Scenario: setting the MCP URL registers the connection, clearing it removes it
    When UCI sets the openwrt-mcp URL
    Then the gateway's configuration has an openwrt server with that URL
    And its Authorization header is a placeholder, never the token
    When UCI clears the URL
    Then that server is gone
    # -> check_mcp_configuration

  Scenario: upstream's own MCP loader receives the token at run time
    Given the MCP URL is set
    When upstream loads its MCP servers with the token in the process environment
    Then the Authorization header it builds carries the token
    And the token is nowhere in the configuration file
    # -> check_mcp_upstream_loader_receives_token

  Scenario: an operator's own openwrt entry is never overwritten
    Given the operator configured an openwrt MCP server of their own
    When UCI sets the MCP URL
    Then the start is refused until the operator renames theirs
    And their entry is unchanged
    # -> check_mcp_collision_preserved

  Scenario: an operator entry identical to the package's own is adopted
    Given the operator wrote exactly the entry the package would write
    When UCI sets the same URL
    Then the start goes ahead and the package takes the entry over
    And clearing the URL later removes it
    # -> check_mcp_identical_manual_entry_is_adopted

  Scenario: a hostile or credential-carrying MCP URL is refused without touching the file
    Given an MCP URL that is a file path, carries a user and password, has an impossible port, is malformed, or holds any of 64 seeded control characters
    When the package validates it
    Then it refuses
    And the configuration file is unchanged
    # -> check_mcp_url_rejection_preserves_config

  # ---- The model and its endpoint ----

  Scenario: the configured endpoint receives a real agent request with the configured model and key
    Given UCI names a model and an OpenAI-compatible endpoint on this machine
    When the agent answers one prompt
    Then the endpoint received the chat request for that model with that key as the bearer
    And the gateway's own model resolver returns the same model
    # -> check_model_endpoint_produces_agent_reply

  Scenario: a model switched from a chat lasts until the next start
    Given a chat switched the model globally, which upstream saves into its configuration
    When the gateway starts again, whether procd restarted it or an operator did
    Then the model, provider and endpoint are the ones UCI names
    And the gateway starts rather than refusing
    # -> check_wrapper_reapplies_uci_after_model_switch

  Scenario: settings that would silently override UCI stop the start
    Given an .env entry, a named provider, a credential pool or an Authorization header that would replace what UCI chose
    When the service starts
    Then it refuses, naming the setting and never its value
    And nothing the operator wrote is changed
    # -> check_runtime_override_conflicts_are_refused

  Scenario: a key the operator put in the configuration is kept and must be moved first
    Given the gateway's configuration holds a model key the operator wrote
    When UCI selects the model
    Then the start is refused and the key is left where it is
    And once the key is moved, UCI's model applies and the operator's other model settings stay
    # -> check_operator_model_key_is_preserved

  Scenario: credential files the upstream would rewrite are refused, spare provider keys are not
    Given an .env file in UTF-16 or with a NUL byte, or a credential pool whose spare key differs
    When the service starts
    Then it refuses and the files keep their exact bytes
    And a separate key for another provider in .env does not stop the start
    # -> check_credential_conflicts_preserve_bytes_and_secondary_keys

  # ---- Credentials ----

  Scenario: no key or token reaches procd's service table
    Given a provider key, a Telegram token and a router MCP token
    When the init hands the service to procd through OpenWrt's own serializer
    Then none of the three values is in what procd stores
    # -> check_all_secrets_absent_from_procd

  Scenario: every start reads the current keys, and switched-off integrations get nothing
    Given the provider key, the Telegram token and the MCP token are rotated between two starts
    When the gateway starts each time
    Then it receives exactly the current values
    And with Telegram and MCP switched off, stale tokens in the environment do not reach it
    # -> check_wrapper_rotation_and_disabled_credentials

  Scenario: a missing router MCP token drops the MCP connection instead of the service
    Given the MCP URL is set and its token file is missing when the gateway starts
    Then the gateway starts without the MCP connection
    And the log names the token file
    And no stale token reaches it
    # -> check_wrapper_drops_mcp_when_token_missing

  Scenario: a missing key says which file is missing
    Given the provider key file or the Telegram token file is missing
    When the gateway starts
    Then it refuses
    And the message names the credential and its path
    # -> check_wrapper_names_the_missing_credential

  # ---- The memory ceiling ----

  Scenario: the memory setting is validated and applied only in the service's own cgroup
    Given memory settings from zero to 1048576 MB, and malformed ones
    Then every valid value converts exactly and every malformed one is refused
    And outside its own procd cgroup, or without the memory controller, the start is refused
    And inside it the ceiling, the swap limit and whole-group termination are written and read back
    # -> check_memory_validation_and_identity

  Scenario: the kernel enforces the ceiling on the real gateway process tree
    Given a ceiling of 64 MB and a process that asks for 128 MB
    When it runs under the wrapper in the service's cgroup, starting from no limit at all
    Then the kernel kills it
    And the cgroup reports the ceiling, no swap, and one more out-of-memory kill than before
    # -> check_memory_kernel_and_fail_closed

  Scenario: zero lifts a ceiling an earlier start applied
    Given an earlier start left a ceiling in the service's cgroup
    When the setting becomes zero
    Then the ceiling, the swap limit and whole-group termination are lifted
    And outside the service's cgroup zero changes nothing and refuses nothing
    # -> check_memory_zero_lifts_previous_ceiling

  Scenario: zero lifts the ceiling in the real kernel too
    Given the gateway ran once under a 256 MB ceiling in its cgroup
    When it starts again with the setting at zero
    Then the kernel reports no memory ceiling and no swap limit for the service
    # -> check_memory_kernel_zero_lifts_ceiling

  # ---- Supervision ----

  Scenario: a gateway that keeps failing at start is stopped, not retried forever
    When the init hands the service to procd
    Then procd retries at most five times when the gateway fails within an hour of starting
    And the wrapper receives the UCI tool list and MCP URL it re-applies at every start
    # -> check_procd_respawn_is_bounded

  Scenario: the agent gives way to the router's own work
    When the init hands the service to procd
    Then procd runs it at a lower priority than the router's own processes
    And the gateway and every tool it starts inherit that priority
    # -> check_gateway_runs_below_the_routers_own_work

  # ---- Further providers ----

  Scenario: several providers are offered at once, each chat on the one it picks
    Given two provider sections in the router's configuration, besides the main model
    When the service starts
    Then upstream resolves each by its name, with the key read from its own file
    And /model lists both beside the main one and switches a chat to either
    And the main model still passes the check made before every start
    # -> check_extra_providers_reach_upstream

  Scenario: a provider section that cannot work refuses the start
    Given a provider named like one upstream already has, or with a bad name, address or model
    When the service starts
    Then it refuses and says why, and the agent's configuration is left as it was
    # -> check_provider_names_upstream_owns_are_refused

  Scenario: the operator's own provider entries are left alone
    Given a provider the operator added to the agent's configuration by hand
    When provider sections are added to or removed from the router's configuration
    Then only the entries the router's configuration made are added or removed
    And one with the same name as the operator's is refused rather than overwritten
    # -> check_operator_provider_entries_survive

  Scenario: each provider's key is read at every start, and a missing one drops only that provider
    Given one provider whose key file is there and one whose key file is missing
    When the gateway starts
    Then the first provider's key reaches the gateway and the second provider is left out
    And the log names the missing file, and the main model starts anyway
    # -> check_wrapper_exports_provider_keys_and_drops_missing_ones

  Scenario: provider keys stay out of procd's service table
    Given a provider section with its key in a root-only file
    When the init hands the service to procd
    Then procd holds the path to the key and never the key
    # -> check_provider_keys_absent_from_procd

  Scenario: a bad provider section anywhere stops the start
    Given a broken provider section followed by a good one
    When the service starts
    Then it refuses and names the broken section
    # -> check_bad_provider_section_refuses_the_start

  Scenario: a leftover setting cannot swap a provider's key
    Given a provider key read from its file at start
    When upstream's own .env names a different key for it
    Then the start is refused without printing either key
    # -> check_preflight_protects_provider_keys

  Scenario: /model does not offer a provider that would leak the main key
    Given the main key held where upstream also looks for an OpenAI API key
    When the service starts
    Then /model does not offer the OpenAI API as a provider
    # -> check_openai_api_is_hidden_from_the_picker

  # @measured 2026-09-25 on a Brume 2 with a Telegram bot: a model picked with /model's
  # buttons worked for that message, and the next turn failed "No LLM provider configured".
  Scenario: a model picked with /model keeps the main key
    Given the main model on OpenRouter or on a machine on the LAN
    When a chat picks another model with /model, with the buttons or typed
    Then the next turn reaches the same endpoint with the main key
    # -> check_model_switch_keeps_the_main_key

  # @measured 2026-09-25 on a Brume 2: a provider on the main model's OpenRouter address
  # refused the start, and a chat switched to it went out with the main key.
  Scenario: a second account on the main model's own service uses its own key
    Given a provider section on the same address as the main model, with a key of its own
    When the service starts and a chat switches to that provider
    Then the start goes ahead and the chat's requests carry that provider's key
    # -> check_provider_on_the_main_endpoint_uses_its_own_key

  Scenario: a chat switched to Anthropic's own endpoint works
    Given the package installed
    Then the library upstream uses for Anthropic's own endpoint is there
    # -> check_native_anthropic_provider_is_installed

  Scenario: a ChatGPT subscription is signed in where the service looks for it
    Given the router's configuration names the service's data directory
    When the owner runs the sign-in command for ChatGPT
    Then it signs in there and nowhere else, and refuses anything but chatgpt
    # -> check_login_helper_uses_the_service_home

  Scenario: signing out of ChatGPT clears the subscription from the router
    Given a ChatGPT subscription signed in in the service's data directory
    When the owner signs out, from the command line or the Providers page
    Then the stored tokens are gone and none of them is printed
    # -> check_login_helper_signs_out

  Scenario: signing in to ChatGPT leaves the main model in charge
    Given a ChatGPT subscription signed in and set as upstream's default by the sign-in
    When the service starts
    Then the main model from the router's configuration is back in place and the start goes ahead
    # -> check_chatgpt_login_does_not_trip_the_preflight
