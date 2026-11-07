# What the agent's own connections reach.
#
# Provenance. No sentence below is a quote.
#
#   @decided 2026-11-07  The agent keeps the internet, its model, DNS and openwrt-mcp. It does not
#                        reach SSH, LuCI or ubus on any address of the router, other services of
#                        the router, other hosts of the house over IPv4 or IPv6, or the tailnet.
#                        An endpoint on the LAN that UCI names keeps working with nothing added
#                        by hand, as decided on 2026-10-05. The protection adds no step for the
#                        owner; one option turns it off and one list adds a host.
#   @claude 2026-11-07   The shape of the rules, why they are in a table of their own and what
#                        each scenario below plants is in CLAUDE.md, invariant 28.
#
# Every scenario runs in OpenWrt's own rootfs with its real nft, fw4 and kernel netfilter: a
# connection is made from the agent's uid to a real listener in a network namespace.
#
# Bound to scripts/gate-network.sh by scripts/gate-scenarios-bound.sh, both ways;
# scripts/teeth-network.py proves the gate can fail.

Feature: The agent reaches the internet and its model, and not the router or the house

  Scenario: the agent does not reach SSH, LuCI or another service of the router
    Given the limits in force
    When the agent connects to the router's ports on its loopback, LAN and WAN addresses, IPv4 and IPv6
    Then every connection is refused at once, and root connects to each of them as before
    # -> check_agent_cannot_reach_router_ports

  Scenario: the agent does not reach another host of the house
    Given a host on the LAN with an IPv4, a ULA, a global and a link-local address
    When the agent connects to each of them
    Then every connection is refused, and root connects as before
    # -> check_agent_cannot_reach_other_lan_hosts

  Scenario: a second network of the house counts as the house
    Given a guest network in a zone of its own
    When the agent connects to a host there
    Then it is refused, while the zone that faces the internet stays open
    # -> check_zones_decide_what_counts_as_the_house

  Scenario: private ranges and the tailnet stay closed whichever way they route
    Given private, carrier-grade and ULA addresses reachable through the WAN side
    When the agent connects to them
    Then every connection is refused, and root connects as before
    # -> check_private_ranges_and_the_tailnet_are_closed

  Scenario: the agent stays in touch with the internet
    Given the limits in force
    When the agent connects to public hosts over IPv4 and IPv6, TCP and UDP
    Then they answer
    # -> check_public_internet_stays_reachable

  Scenario: a model on the LAN named in the settings works with nothing added by hand
    Given hermes.main.base_url or a provider section names a host on the LAN, by address or by name
    When the limits are applied
    Then the agent reaches that port of that host, and no other port of it
    # -> check_lan_endpoint_from_uci_works_without_a_step

  Scenario: the agent reaches openwrt-mcp and llm-gateway
    Given openwrt-mcp and llm-gateway on the router's loopback
    When the agent connects to their ports
    Then they answer, at the port the settings name
    # -> check_mcp_and_gateway_stay_reachable

  Scenario: DNS works as before, wherever the resolver is
    Given the router's own resolver, and then a resolver on the LAN named in resolv.conf
    When the agent asks over UDP and TCP
    Then it answers, and the LAN resolver's other ports stay closed
    # -> check_dns_reaches_the_resolver

  Scenario: the agent cannot allow itself a host with its own files
    Given a host of the house named in config.yaml and .env in the agent's data directory
    When the limits are applied
    Then that host stays closed, and the rules hold nothing from those files
    # -> check_allow_list_ignores_the_agents_own_files

  Scenario: one option turns the limits off
    Given the limits in force
    When they are switched off
    Then the table is gone, nothing is written for the firewall to load, and the agent reaches the house
    # -> check_open_turns_the_limits_off

  Scenario: the owner can add a host
    Given list lan_allow names a host and a port
    When the limits are applied
    Then the agent reaches that port of that host over TCP and UDP, and an entry that makes no sense is left out and named
    # -> check_lan_allow_adds_a_host

  Scenario: what the settings name never opens the router's own door
    Given an endpoint or a lan_allow entry that names SSH or LuCI on an address of the router, by address or by a name that resolves to it
    When the limits are applied
    Then those ports stay closed, on the port the router's own settings give them too
    # -> check_router_ports_stay_closed_whatever_uci_names

  Scenario: a firewall reload leaves the limits in force
    Given the limits in force
    When fw4 reloads
    Then the table is still there and the agent is still refused
    # -> check_firewall_reload_keeps_the_table

  Scenario: a firewall restart leaves the limits in force
    Given the limits in force
    When fw4 restarts
    Then the table is still there and the agent is still refused
    # -> check_firewall_restart_keeps_the_table

  Scenario: a stopped firewall brings the limits back when it starts
    Given the limits in force
    When the firewall is stopped, which deletes every table, and started
    Then the include puts the table back
    # -> check_firewall_stop_start_restores_it

  Scenario: a defect in the limits cannot touch the router's firewall
    Given rules that nft refuses
    When they are applied
    Then the check stops them, the minimal rules go in instead, and fw4's own table is as it was
    And when even those are refused the command says so and fails, and the table of fw4 is still as it was
    # -> check_bad_rules_leave_the_firewall_alone

  Scenario: the limits are a table of their own and never a rule of fw4
    Given fw4 running
    When the limits are applied
    Then fw4's table is unchanged, and the rules name no other table
    # -> check_rules_stay_out_of_fw4

  Scenario: the match on the agent is positive, and packets without a socket are never touched
    Given the limits in force
    When the router's own kernel answers a host of the house with a reset or an ICMP error
    Then that packet leaves, and the output chain holds one positive match on the agent's uid
    # -> check_packets_with_no_socket_still_leave

  Scenario: every refusal sits inside the agent's chain
    Given the limits in force
    Then the base chain accepts by default and refuses nothing, and every refusal is in chain agent
    # -> check_every_refusal_sits_in_chain_agent

  Scenario: the firewall's include runs nft and nothing else
    Given the script fw4 runs at every start and reload
    Then it calls neither fw4 nor uci, and fw4 reloads in the time it takes without it
    # -> check_include_never_calls_fw4

  Scenario: the agent's uid is read when the rules are written
    Given the account hermes with another id
    When the limits are applied
    Then the rules match that id
    # -> check_uid_is_read_at_apply_time

  Scenario: the limits touch the agent's user and no one else
    Given the limits in force
    When root and another unprivileged user connect to what the agent may not reach
    Then they connect as before, so the owner's own SSH and LuCI are as they were
    # -> check_limits_touch_no_other_user

  Scenario: the agent is no server for the house
    Given a listener the agent opened on all addresses
    When a host of the house connects and waits for an answer
    Then nothing comes back, and a client on the router's loopback gets its answer
    # -> check_agent_is_no_server_for_the_house

  Scenario: a dead endpoint can be diagnosed
    Given the limits in force
    When the agent is refused
    Then the drop counter goes up, status says so, and the rule that refused it logs the address
    # -> check_drop_counter_and_log_line

  Scenario: a value in the settings cannot write a rule
    Given device names and hosts in UCI that carry nft syntax
    When the limits are applied
    Then each is left out and named, and the rules are the same as without them
    # -> check_hostile_uci_values_write_no_rule

  Scenario: a name that does not resolve costs one line
    Given an endpoint whose name does not resolve
    When the limits are applied
    Then they go in, and one line names the setting and the host
    # -> check_a_name_that_does_not_resolve_is_named_and_left_out

  Scenario: a new interface brings its device into the rules
    Given the limits in force
    When an interface of the house comes up
    Then the hotplug script applies the rules again without being waited for
    # -> check_interface_event_reapplies_the_rules

  Scenario: a name in the settings starts working when its lease comes
    Given a model on the LAN named by a name that answers nothing yet, as after a reboot of the router
    When that computer takes its lease
    Then the hotplug script applies the rules again, and the agent reaches that port of that host
    # -> check_a_lease_gives_a_name_in_uci_its_address

  Scenario: a start that changes nothing writes nothing
    Given the limits in force and the include section written
    When the limits are applied again
    Then the firewall's file is untouched and the drop counter keeps its count
    # -> check_a_start_that_changes_nothing_writes_nothing

  Scenario: the include section is added without taking anyone's staged changes
    Given a firewall change staged and not committed
    When the limits write their include section
    Then the staged change stays staged and is not in the file
    # -> check_include_section_leaves_staged_changes_alone
