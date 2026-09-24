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
