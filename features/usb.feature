# Hermes's data on a USB stick, as an option.
#
# Provenance. No sentence below is a quote.
#
#   @decided 2026-10-04  Hermes installs to the router's own storage by default. Putting it
#                        on a USB stick is an option for people who would rather not have a
#                        heavy service writing to storage they cannot replace, and it has to
#                        be as simple as one command.
#   @measured 2026-10-04 on a Flint 2 and a Brume 2, with the data directory alone on a stick
#                        and ext4's background inode-table initialisation paused: about 1 GB a
#                        day written by an idle gateway, journal included, against 2.3 and 5.7
#                        GB a day that the routers themselves wrote to their eMMC in the same
#                        half hours. What wears storage is what is written again and again,
#                        and that is the data directory; the programs are written once.
#   @claude 2026-10-04   So the command moves the data directory, not the programs. A router
#                        whose writable layer lives on the stick (extroot) is the README's
#                        advanced path for routers with too little flash, not this command.
#                        Without the stick, Hermes does not start rather than start empty on
#                        internal storage; the router itself never depends on the stick.
#
# Bound to scripts/gate-usb.sh by scripts/gate-scenarios-bound.sh, both ways;
# scripts/teeth-usb.sh proves the gate can fail.

Feature: Hermes's data moves to a USB stick with one command, and back

  Scenario: the command says where the data lives
    Given Hermes with its data directory on the router's own storage
    When the owner runs hermes-usb status
    Then it names the data directory, the storage it is on, and its size
    # -> check_status_names_where_data_lives

  Scenario: the data moves to a stick and the agent comes back up on it
    Given Hermes running with data in its data directory, and an ext4 stick
    When the owner runs hermes-usb move with the stick's partition
    Then the gateway is stopped before anything is copied
    And every file arrives on the stick unchanged
    And the stick is mounted on the data directory by its UUID, from the router's fstab
    And the agent starts again as hermes, with its data on the stick
    And the copy left on the router's own storage is removed
    # -> check_move_copies_and_restarts_on_the_stick

  Scenario: a stick that is in use, or the router's own storage, is refused
    Given a partition that is mounted somewhere already, or that holds the router's own layer
    When the owner runs hermes-usb move with it
    Then the command refuses, names the reason, and changes nothing
    # -> check_move_refuses_a_device_in_use

  Scenario: a stick without room is refused
    Given a stick with less free space than the data directory needs
    When the owner runs hermes-usb move with it
    Then the command refuses, says how much is needed, and changes nothing
    # -> check_move_refuses_a_stick_without_room

  Scenario: a stick that is not ext4 is formatted only when the owner says so
    Given a partition with another filesystem on it
    When the owner runs hermes-usb move without --format
    Then the command refuses and says --format would erase it
    When the owner runs it with --format
    Then the partition is formatted ext4 with every inode table written at once, so the
    And new filesystem does not keep writing on its own for hours afterwards
    # -> check_format_only_when_asked_and_without_lazy_init

  Scenario: without the USB tools nothing happens, and the command says what to install
    Given a router without the USB storage and ext4 packages
    When the owner runs hermes-usb move
    Then the command prints the one apk add line that installs them, and changes nothing
    # -> check_missing_tools_named_and_nothing_changed

  Scenario: without the stick, Hermes does not start, and says why
    Given Hermes whose data was moved to a stick
    And the stick is not there when the service starts
    When the service starts
    Then the gateway does not run, nothing is written to the router's own storage
    And the log says the stick holding Hermes's data is missing
    # -> check_missing_stick_stops_the_start

  Scenario: the data comes back to the router's own storage
    Given Hermes with its data on a stick
    When the owner runs hermes-usb back
    Then every file returns to the router's own storage unchanged
    And the fstab entry is removed and the agent starts with its data inside
    # -> check_back_returns_the_data_inside
