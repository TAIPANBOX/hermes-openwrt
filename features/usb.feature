# Hermes's data on a USB stick, as an option.
#
# Provenance. No sentence below is a quote.
#
#   @decided 2026-10-04  Hermes installs to the router's own storage by default. Putting it
#                        on a USB stick is an option for people who would rather not have a
#                        heavy service writing to storage they cannot replace, and it has to
#                        be as simple as one command.
#   @measured 2026-10-04 on a Flint 2 and a Brume 2: sectors written to the stick, field 10
#                        of `awk '$3 == "sda"' /proc/diskstats`, read before and after 1800 s,
#                        with the data directory alone on it and ext4 mounted noinit_itable: about 1 GB a
#                        day written by an idle gateway, journal included, against 2.3 and 5.7
#                        GB a day that the routers themselves wrote to their eMMC in the same
#                        half hours. What wears storage is what is written again and again,
#                        and that is the data directory; the programs are written once.
#   @claude 2026-10-04   So the command moves the data directory, not the programs. A router
#                        whose writable layer lives on the stick (extroot) is the README's
#                        advanced path for routers with too little flash, not this command.
#                        Without the stick, Hermes does not start rather than start empty on
#                        internal storage; the router itself never depends on the stick. The
#                        record of the stick is one fstab section, written and removed in one
#                        commit each, and one check reads it for the init, the gateway wrapper
#                        procd respawns, hermes-login and the block hotplug script.
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
    Then the gateway has exited, its last write made, before anything is copied
    And every file arrives on the stick unchanged
    And the stick is mounted on the data directory by its UUID, from the router's fstab, again at the next mount
    And the agent starts again as hermes, with its data on the stick
    And the copy left on the router's own storage is removed, only once the stick is mounted
    And the started agent's own init takes the stick hermes-usb set up
    And so does a hermes command, run as the gateway runs it and from a root shell
    # -> check_move_copies_and_restarts_on_the_stick

  Scenario: only a partition of a USB stick with nothing in use on it is taken
    Given a partition that is not on USB, a whole disk, or a partition of a disk that has
    And another of its partitions mounted
    When the owner runs hermes-usb move with it
    Then the command refuses, names the reason, and changes nothing
    # -> check_move_refuses_a_device_in_use

  Scenario: a data directory already set up by hand is left alone
    Given a data directory that is a mount point already, reached through a symbolic link,
    And on a filesystem other than the router's own, named in the fstab, or in a system tree
    When the owner runs hermes-usb move
    Then the command refuses, says what to undo first, and changes nothing
    # -> check_move_refuses_a_data_dir_set_up_by_hand

  Scenario: a copy that does not match switches nothing
    Given a copy that comes out different from the data directory
    When the owner runs hermes-usb move
    Then nothing is switched, the data stays where it was, and the agent starts there again
    # -> check_copy_that_differs_switches_nothing

  Scenario: a stick without room is refused
    Given a stick with less room than the data directory needs
    When the owner runs hermes-usb move with it, with or without --format
    Then the command refuses, says how much is needed, and changes nothing, the stick included
    # -> check_move_refuses_a_stick_without_room

  Scenario: a stick that is not ext4 is formatted only when the owner says so
    Given a partition with another filesystem on it
    When the owner runs hermes-usb move without --format
    Then the command refuses and says --format would erase it
    When the owner runs it with --format
    Then the partition is formatted ext4 with every inode table written at once, so the
    And new filesystem does not keep writing on its own for hours afterwards
    And with no blocks reserved for root, which the agent, running as hermes, could not use
    # -> check_format_only_when_asked_and_without_lazy_init

  Scenario: without the USB tools nothing happens, and the command says what to install
    Given a router without the USB storage and ext4 packages
    When the owner runs hermes-usb move
    Then the command prints the one apk add line that installs them, and changes nothing
    # -> check_missing_tools_named_and_nothing_changed

  Scenario: without the stick, nothing of Hermes writes inside, and each says why
    Given Hermes whose data was moved to a stick
    And the stick is not there
    When the service starts, procd respawns the gateway, a hermes command is pointed at the
    And data directory, or the ChatGPT sign-in runs
    Then each refuses, says the stick holding Hermes's data is missing
    And nothing is written to the router's own storage
    And the stick mounted on a parent of the data directory is not taken for it
    And a record of the stick that is disabled or names no UUID is refused, never read as
    And the data being inside
    And a different stick in its place is refused the same way
    And with the right stick mounted the start goes on
    # -> check_missing_stick_stops_the_start

  Scenario: the stick coming and going starts and stops Hermes
    Given Hermes enabled, with its data on a stick
    When the stick is plugged in and mounted
    Then Hermes starts, and a stick late at boot needs no wait
    When the service is disabled and the stick is plugged in
    Then nothing starts
    When another device comes while Hermes is stopped, or goes while it runs on its stick
    Then nothing starts and nothing stops
    When the stick goes
    Then Hermes is stopped, so nothing restarts it on the router's own storage
    # -> check_stick_coming_and_going

  Scenario: the data comes back to the router's own storage
    Given Hermes with its data on a stick
    When the owner runs hermes-usb back, and only from the stick the data belongs on
    Then every file returns to the router's own storage unchanged
    And anything that lay underneath the mount point is kept aside, not deleted
    And what fsck recovered into the stick's lost+found comes inside with the rest
    And the fstab entry is removed last, in one commit, and the agent starts with its data inside
    # -> check_back_returns_the_data_inside

  Scenario: a move whose mount fails puts everything back
    Given the stick cannot be mounted on the data directory once the copy is made
    When the owner runs hermes-usb move
    Then the command says nothing was switched
    And the data is in the data directory as it was, with no copy left beside it
    And no fstab entry was written, and the agent starts again where it was
    # -> check_failed_mount_puts_everything_back

  Scenario: a back that cannot finish puts the stick back
    Given the copy brought inside cannot be put in place
    When the owner runs hermes-usb back
    Then the command says nothing was switched
    And the stick is mounted on the data directory again, its data unchanged
    And its fstab entry is still there, no half-made copy is left inside
    And the agent starts again on the stick
    # -> check_failed_back_puts_the_stick_back

  Scenario: nothing starts on a move that is running or was interrupted
    Given hermes-usb is moving the data, or a power cut left the copy it set aside
    When the service starts or procd respawns the gateway
    Then it refuses, and the copy an interrupted move or back left is named
    And a lock left by a hermes-usb that is gone, or holding a pid now another program's, does
    And not block anything
    And a new move refuses to run beside the copy left behind, and leaves it alone
    # -> check_interrupted_or_running_move_starts_nothing

  Scenario: a lost stick can be given up
    Given the record of a stick that is not there any more
    When the owner runs hermes-usb forget without --yes, or with the stick mounted
    Then nothing is given up
    When the owner runs hermes-usb forget --yes with the stick gone
    Then the record is removed, the data on the stick is not touched
    And Hermes starts again with an empty data directory inside
    # -> check_lost_stick_forgotten

  Scenario: the stick's record is on flash before anything inside is let go
    Given changes to the router's fstab that someone else has left uncommitted
    When the owner runs hermes-usb move
    Then the command refuses, names them, and commits nothing of anyone else's
    And a change someone starts while the copy runs is caught the same way before the switch
    Given the router's own storage too full to record the stick
    When the owner runs hermes-usb move
    Then the command refuses before the agent is stopped, and changes nothing
    Given a commit of the fstab that reports success and leaves nothing on flash
    When the owner runs hermes-usb move
    Then nothing is switched, the data is inside as it was, the agent starts there again
    And the same holds for a commit cut off inside a value after the record's target
    And no record of the stick is left anywhere a reader would take for flash
    When the owner runs hermes-usb back with such a commit
    Then it does not say the stick can be removed, and Hermes does not start inside while
    And flash still says its data is on the stick
    Given a commit that reports success and leaves the file empty or unreadable
    When the owner gives the stick up with hermes-usb forget --yes
    Then it does not say the stick is given up
    And the file is put back as it was, with every other section in it
    And a file left that uci cannot read is put back the same way
    And with no copy of the file to put back, nothing is committed at all
    # -> check_stick_record_proven_on_flash

  Scenario: the data is not moved while anything else is using it
    Given a process with a file open, or its working directory, in the data directory
    And the file's name may have a space in it, or the file may be deleted while held open
    When the owner runs hermes-usb move
    Then the command refuses, names the process, and changes nothing
    And a hermes command started from a root shell while a move runs is refused, however the
    And data directory's path is spelled, and runs once the move has finished
    # -> check_move_refuses_while_another_process_uses_the_data
