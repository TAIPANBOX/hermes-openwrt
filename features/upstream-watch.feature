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

  Scenario: a tag in a form the check cannot order fails instead of going quiet
    Given upstream's latest release is tagged outside the vYEAR.MONTH.DAY form
    When the daily check runs
    Then it fails and says it cannot compare that tag
    And it opens no issue
    # -> check_refuses_unrecognised_tag
