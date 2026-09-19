# @measured scripts/test-runtime.py against b39861b 2026-09-19: runtime regressions reproduced.
Feature: Gateway runtime controls match the shipped payload

  # -> check_gateway_selection
  Scenario: gateway selection
    Given the packaged upstream payload on OpenWrt
    When the runtime control is exercised by test_gateway_selection
    Then its asserted runtime contract holds

  # -> check_empty_selection
  Scenario: empty selection
    Given the packaged upstream payload on OpenWrt
    When the runtime control is exercised by test_empty_selection
    Then its asserted runtime contract holds

  # -> check_bad_yaml_is_fatal_and_preserved
  Scenario: bad yaml is fatal and preserved
    Given the packaged upstream payload on OpenWrt
    When the runtime control is exercised by test_bad_yaml_is_fatal_and_preserved
    Then its asserted runtime contract holds

  # -> check_unknown_toolset_is_fatal
  Scenario: unknown toolset is fatal
    Given the packaged upstream payload on OpenWrt
    When the runtime control is exercised by test_unknown_toolset_is_fatal
    Then its asserted runtime contract holds

  # -> check_mcp_configuration
  Scenario: mcp configuration
    Given the packaged upstream payload on OpenWrt
    When the runtime control is exercised by test_mcp_configuration
    Then its asserted runtime contract holds

  # -> check_mcp_collision_preserved
  Scenario: mcp collision preserved
    Given the packaged upstream payload on OpenWrt
    When the runtime control is exercised by test_mcp_collision_preserved
    Then its asserted runtime contract holds

  # -> check_config_preserves_other_settings
  Scenario: config preserves other settings
    Given the packaged upstream payload on OpenWrt
    When the runtime control is exercised by test_config_preserves_other_settings
    Then its asserted runtime contract holds

  # -> check_mcp_url_rejection_preserves_config
  Scenario: mcp url rejection preserves config
    Given the packaged upstream payload on OpenWrt
    When the runtime control is exercised by test_mcp_url_rejection_preserves_config
    Then its asserted runtime contract holds

  # -> check_mcp_upstream_loader_receives_token
  Scenario: mcp upstream loader receives token
    Given the packaged upstream payload on OpenWrt
    When the runtime control is exercised by test_mcp_upstream_loader_receives_token
    Then its asserted runtime contract holds

  # -> check_wrapper_rotation_and_disabled_credentials
  Scenario: wrapper rotation and disabled credentials
    Given the packaged upstream payload on OpenWrt
    When the runtime control is exercised by test_wrapper_rotation_and_disabled_credentials
    Then its asserted runtime contract holds

  # -> check_memory_validation_and_identity
  Scenario: memory validation and identity
    Given the packaged upstream payload on OpenWrt
    When the runtime control is exercised by test_memory_validation_and_identity
    Then its asserted runtime contract holds

  # -> check_memory_kernel_and_fail_closed
  Scenario: memory kernel and fail closed
    Given the packaged upstream payload on OpenWrt
    When the runtime control is exercised by test_memory_kernel_and_fail_closed
    Then its asserted runtime contract holds

  # -> check_all_secrets_absent_from_procd
  Scenario: all secrets absent from procd
    Given the packaged upstream payload on OpenWrt
    When the runtime control is exercised by test_all_secrets_absent_from_procd
    Then its asserted runtime contract holds

  # -> check_existing_plugin_and_mcp_selection_survives
  Scenario: Existing plugin and MCP selection survives
    Given explicitly enabled and disabled plugins plus an MCP opt-out
    When UCI replaces the built-in tool defaults
    Then the upstream resolver preserves the operator plugin and MCP choices

  # -> check_model_endpoint_produces_agent_reply
  Scenario: The configured model endpoint receives an actual agent request
    Given the OpenWrt UCI model settings
    When test_model_endpoint_produces_agent_reply exercises the upstream runtime
    Then the selected primary endpoint and credential are used or startup is refused

  # -> check_runtime_override_conflicts_are_refused
  Scenario: Conflicting upstream runtime overrides refuse startup
    Given the OpenWrt UCI model settings
    When test_runtime_override_conflicts_are_refused exercises the upstream runtime
    Then the selected primary endpoint and credential are used or startup is refused

  # -> check_operator_model_key_is_preserved
  Scenario: Operator model credentials and unrelated settings survive
    Given the OpenWrt UCI model settings
    When test_operator_model_key_is_preserved exercises the upstream runtime
    Then the selected primary endpoint and credential are used or startup is refused

  # -> check_credential_conflicts_preserve_bytes_and_secondary_keys
  Scenario: Credential conflicts preserve bytes and secondary provider keys
    Given a malformed dotenv file or a primary credential pool with a conflicting spare
    When the gateway validates the upstream configuration
    Then it refuses without rewriting credentials and permits independent secondary keys
