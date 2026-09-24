# What the feed serves.
#
# Provenance. Nobody asked for this in words. It comes from a measurement on 2026-09-15:
# a router on aarch64_cortex-a53 installed hermes-agent r4 from the feed and had no
# bash, while the aarch64_generic and x86_64 packages of the same release declared it.
# The relabelled package is produced by a second `apk mkpkg` call, and that call had
# its own copy of the dependency list. The scenario below is @claude, derived from that
# @measured fact, and is not a quote from anyone.
#
# Each scenario is bound to a named check; scripts/gate-scenarios-bound.sh asserts the
# binding both ways.

Feature: a package relabelled for another architecture is the same package

  Scenario: the relabelled package differs from the primary in nothing but its label
    Given the primary package built for aarch64_generic
    And the same tree emitted again under the label aarch64_cortex-a53
    When the two package databases are compared without the arch, its hash and its size
    Then they are identical
    # -> check_relabel_identical
