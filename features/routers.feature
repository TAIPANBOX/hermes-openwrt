# Which routers this repository names.
#
# Provenance. No sentence below is a quote.
#
#   @decided 2026-09-24  The routers this package is built for and checked on, and the
#                        only ones the repository names, are the GL.iNet Flint 2 and
#                        Brume 2: two form factors of the same job, one with Wi-Fi and
#                        one without. A finding made on another box is described by its
#                        architecture.
#   @decided 2026-10-04  The Beryl AX joins them as a third test router, the one with
#                        512 MB of memory and little flash, where Hermes runs from a USB
#                        stick. The lab's other box is still not named.
#
# Bound to scripts/gate-named-routers.sh by scripts/gate-scenarios-bound.sh, both ways;
# scripts/teeth-named-routers.sh proves the gate can fail.

Feature: The repository names only the routers it is tested on

  Scenario: no other router is named anywhere in the repository
    Given every file the repository tracks
    When they are searched for the lab's other routers, by name and by model number
    Then none of them is found
    # -> check_names_only_the_test_routers
