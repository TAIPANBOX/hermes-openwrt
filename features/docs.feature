# The documentation's figures and links.
#
# Provenance. No sentence below is a quote.
#
#   @decided 2026-10-05   The README was too long to find anything in. It keeps the install
#                         steps, for a person and an agent alike, and shows the measured runs as
#                         figures and tables; the long explanations move to docs/, and an agent
#                         that installs Hermes gets a guide of its own (docs/agent-install.md).
#   @claude 2026-10-05    How it stays true is mine: the figures are drawn by a script from one
#                         data file, and every picture, link and anchor is checked to resolve.
#
# Bound to scripts/gate-figures.sh by scripts/gate-scenarios-bound.sh, both ways;
# scripts/teeth-figures.sh proves the gate can fail.

Feature: The README's figures and links stay true after the text moved

  Scenario: a figure shows the numbers in its data file
    Given the measured figures are kept in docs/measurements/figures.json
    When the figures are drawn again from that file
    Then they are exactly the SVGs the README shows
    # -> check_figures_match_their_data

  Scenario: every picture the documentation shows exists
    Given README.md, CONTRIBUTING.md, SECURITY.md and docs/*.md
    When every image they show is looked up
    Then each is a file in the repository
    # -> check_doc_images_exist

  Scenario: a link to a section that moved still reaches it
    Given a section moved from the README to a file under docs/
    When every relative link and #anchor in the documentation is followed
    Then each reaches a file, and a heading in it for the anchor
    # -> check_doc_links_resolve
