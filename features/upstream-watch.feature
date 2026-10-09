# Noticing a new upstream Hermes release.
#
# Provenance. No sentence below is a quote.
#
#   @claude 2026-10-04   Asked for with the other tails closed before outside testing: the
#                        README's open Status line "track upstream releases automatically".
#                        How it is done is mine: a daily job compares the pinned tag with
#                        upstream's latest release and opens one issue for a newer one.
#                        Moving the package to it stays a reviewed change, because a new
#                        upstream has to be built, gated and run on both routers first.
#   @claude 2026-10-09   Upstream changed its tag scheme: releases up to 0.21.5 were tagged
#                        vYEAR.MONTH.DAY (v2026.9.24), 0.21.6 is tagged v0.21.6. The check
#                        refused the new tag, so a newer Hermes showed up only as a red
#                        daily run. Releases are now compared by the Hermes version they
#                        carry: a vX.Y.Z tag is that version, a date tag is the version its
#                        release name gives ("Hermes Agent v0.21.5 (v2026.9.24)"), and the
#                        pin is HERMES_VERSION, which the build's own gate checks.
#
# Bound to scripts/gate-upstream-watch.sh by scripts/gate-scenarios-bound.sh, both ways;
# scripts/teeth-upstream-watch.sh proves the gate can fail.

Feature: A newer upstream Hermes is noticed without anyone looking

  Scenario: nothing happens while the package carries upstream's latest release
    Given the tag the repository pins is upstream's latest release
    When the daily check runs
    Then it opens no issue and succeeds
    # -> check_quiet_when_pinned_is_latest

  Scenario: a newer upstream release opens one issue that names both versions
    Given upstream has tagged a release newer than the pinned one
    When the daily check runs
    Then it opens an issue naming the new tag and the pinned tag
    And the issue says the new release is built, gated and run on both routers before it is published
    # -> check_issue_when_upstream_is_newer

  Scenario: the same release never opens a second issue, even after the first was closed
    Given an issue for that release already exists, open or closed
    And the pin may have moved since that issue was opened
    When the daily check runs again
    Then it opens no issue
    # -> check_no_second_issue

  Scenario: an older upstream release is not news
    Given the pinned tag is newer than upstream's latest release
    When the daily check runs
    Then it opens no issue
    # -> check_quiet_when_pinned_is_ahead

  Scenario: a check that cannot read upstream fails instead of passing
    Given upstream's latest release cannot be read, or reads as empty
    When the daily check runs
    Then it fails and says it could not read upstream
    And it opens no issue
    # -> check_refuses_when_upstream_unreadable

  Scenario: a check that cannot read the existing issues opens none
    Given upstream has a newer release, and this repository's issues cannot be read
    When the daily check runs
    Then it fails and says it could not read the issues
    And it opens no issue, since it cannot know whether one exists
    # -> check_refuses_when_issues_unreadable

  Scenario: a release in the new vX.Y.Z tag scheme is news over a pin in the date scheme
    Given the repository pins a release tagged by date, carrying Hermes 0.21.5
    And upstream's latest release is tagged v0.21.6
    When the daily check runs
    Then it opens one issue naming v0.21.6 and the pinned tag
    # -> check_issue_when_semver_after_date_pin

  Scenario: the pinned version under a tag in the other scheme is not news
    Given the repository pins Hermes 0.21.5, tagged by date
    And upstream's latest release is the same version, tagged v0.21.5
    When the daily check runs
    Then it opens no issue and succeeds
    # -> check_quiet_when_same_version_new_scheme

  Scenario: releases in either scheme are ordered by the Hermes version they carry
    Given a pin and an upstream release, each tagged by date or as vX.Y.Z
    When the daily check runs
    Then it opens an issue only when upstream's version is later than the pinned version
    And a later date on an older version is not news, and 0.21.10 is later than 0.21.6
    # -> check_mixed_schemes_order_by_version

  Scenario: a tag or a version the check cannot order fails instead of going quiet
    Given upstream's latest tag is in neither scheme
    But the same holds for a date tag whose release name carries no version
    And for a vX.Y.Z tag whose release name gives another version
    And for a pinned version that is not X.Y.Z, or a pinned vX.Y.Z tag that is not the pinned version
    When the daily check runs
    Then it fails and says it cannot compare
    And it opens no issue
    # -> check_refuses_unrecognised_tag
