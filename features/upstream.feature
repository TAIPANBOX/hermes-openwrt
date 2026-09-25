# Which Hermes the package carries, and where it comes from.
#
# Provenance. No sentence below is a quote.
#
#   @decided 2026-09-25  The package moves from Hermes 0.19.0 to 0.21.5, built from a
#                        pinned tag of the upstream GitHub repository, because PyPI
#                        stopped at 0.19.0.
#   @decided 2026-09-25  The router package leaves out two heavy upstream dependencies:
#                        NVIDIA's Relay runtime (nemo-relay), which upstream replaces
#                        with a no-op where it is absent, and the HEIC/AVIF image decoder
#                        (pillow-heif). The rest of upstream's dependency set ships as
#                        upstream locks it.
#
#   @claude 2026-09-25   Upstream now refuses to build a wheel outside its Nix build
#                        (setup.py raises unless HERMES_NIX_BUILD=1) and ships skills,
#                        locales and the MCP catalogue beside the wheel, found through
#                        HERMES_BUNDLED_* variables. The package reproduces that layout.
#
# Bound to scripts/gate-upstream.sh by scripts/gate-scenarios-bound.sh, both ways;
# scripts/teeth-upstream.sh proves the gate can fail.

Feature: The package carries a pinned upstream Hermes, without two heavy parts

  Scenario: the source is the pinned upstream commit, byte for byte
    Given the upstream version, commit and archive checksum the repository pins
    When the package is built
    Then it was built from that commit's archive and no other
    And the package records which commit it carries
    # -> check_upstream_pinned

  Scenario: the router runs the version the repository pins
    Given the package installed on OpenWrt
    When the agent reports its version
    Then it is the pinned upstream version
    # -> check_version_is_upstream

  Scenario: every library is the version upstream locked
    Given the libraries the package ships
    When each is compared with upstream's lock file at that commit
    Then every one has the locked version
    # -> check_versions_follow_lock

  Scenario: the two left-out parts are really left out
    Given the libraries the package ships
    When they are searched for NVIDIA's Relay runtime and the HEIC decoder
    Then neither is there, nor anything that only they needed
    # -> check_excluded_absent

  Scenario: without the Relay runtime the agent still works
    Given the package installed on OpenWrt, without the Relay runtime
    When the agent sets up its Relay host
    Then it falls back to upstream's no-op host instead of failing
    # -> check_relay_falls_back

  Scenario: skills, translations and the MCP catalogue are found
    Given the package installed on OpenWrt
    When the agent looks for its bundled skills, optional skills, translations and MCP catalogue
    Then each is found where the package put it, and is not empty
    And a translated message reads as text, not as its key
    # -> check_assets_resolve

  Scenario: the platform plugins ship, Telegram among them
    Given the package installed on OpenWrt
    When the agent discovers its bundled plugins
    Then the Telegram platform is among them
    # -> check_platform_plugins_ship
