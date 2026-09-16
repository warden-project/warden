# Warden

Warden is a menu-driven TUI for managing Network-Bound Disk Encryption
(NBDE) on Ubuntu Server hosts: installing and configuring Tang and
Clevis, binding LUKS-encrypted drives to Tang servers (including over
Tailscale), and handling the ongoing lifecycle — key rotation, header
backups, uninstall, and secure disposal.

## Scope

Ubuntu Server hosts only. The Tang server running as a Docker container
on a separate Unraid NAS is out of scope and is managed through
Unraid's own Docker UI. Where an Ubuntu host runs Tang itself as a
native systemd service, that is in scope.

## Status

**Phase 1 complete.** Core safety primitives (logging, dry-run-aware
command execution, device/UUID resolution, the root/boot/EFI guard,
typed confirmation, backup-before-edit) are in place and tested.
Menu 1 (install components) and menu 7 (status dashboard) are
implemented — both non-destructive. Everything from menu 2 onward is
not yet built. See the wiki for the full roadmap.

## Prerequisites

- Ubuntu Server 24.04 LTS
- `whiptail` (present by default on Ubuntu Server)
- Root privileges to run `bin/warden` (see Safety model)

For development/testing: `shellcheck`, [`bats`](https://github.com/bats-core/bats-core).

## Quick start

```sh
sudo bin/warden
```

## Architecture

Bash + whiptail, not a larger framework: given that this tool edits
disk encryption configuration and, in one path, can permanently destroy
data, every action needs to stay readable and auditable line-by-line
rather than hidden behind abstraction.

```
bin/warden          entrypoint: root check, sourcing, main menu loop
lib/core/           safety primitives — see "Safety model" below
lib/tui/            whiptail wrappers
lib/features/       one file per menu item (added as each phase lands)
tests/bats/         test suite, run against loop-device-backed images
docs/               usage docs per menu path
wiki/               mirrors the Forgejo wiki
```

Every mutating command in every feature routes through
`lib/core/exec.sh`'s `run_cmd`, which is the single chokepoint that
makes dry-run and logging structural guarantees rather than something
each wizard has to remember to implement.

## Safety model

These requirements are non-negotiable, and two of them exist because of
real incidents, not hypothetical caution:

- **State is checked before every action.** Running Warden twice, or
  interrupting it (Ctrl-C, power loss, reboot) and running it again,
  must never leave the system inconsistent or redo completed work.
- **Devices are resolved by UUID, never by `/dev/sdX` name**, which is
  not stable across reboots. Device letters may appear in menus for
  readability but are always re-resolved before use.
- **The root/boot/EFI guard.** Before any destructive disk operation,
  Warden shows the current `lsblk -f` view, refuses by default if the
  target is or backs the current root filesystem, `/boot`, or
  `/boot/efi`, and requires a distinct typed-confirmation override to
  proceed. This exists because of a near-miss where an EFI boot
  partition was almost run through `cryptsetup luksFormat` by mistake —
  the operator was confident, just wrong about the target, so a plain
  y/n confirmation would not have caught it.
- **Destructive confirmations are typed, never y/n**, and are bound to
  the specific device on screen (e.g. a UUID fragment), not a
  memorizable fixed phrase — so the confirmation can't be given on
  autopilot for the wrong device.
- **Backup before editing.** `/etc/crypttab` and `/etc/fstab` are never
  edited in place without a timestamped backup first, and edits are
  minimal/targeted appends rather than wholesale regeneration, so
  unrelated existing entries are never touched or reordered.
- **Dry-run mode for every wizard**, showing exactly what would run
  and change before anything is committed.
- **Every action is logged** to a timestamped session log: commands
  run, files changed, before/after diffs. Recovery passphrases
  themselves are the one deliberate exception — Warden logs that a
  passphrase was set, never the passphrase value.
- **Idempotent installs.** Package installs, systemd unit enablement,
  and crypttab/fstab entries are all checked before being added. This
  exists because of a confirmed incident where `clevis-systemd` was
  missed on install, silently breaking late-boot unlock — every
  required package is checked explicitly and individually, never
  assumed to ride in with a related one.

See the wiki's "Lessons learned" page for the full background on both
incidents.

## Testing

The test suite runs against loop-device-backed sparse image files
(`truncate` + `losetup` + real `cryptsetup`/LUKS), never real hardware:

```sh
bats tests/bats/
```

Some tests require root (anything that actually formats a loop device)
and are skipped otherwise. CI runs the full suite as root.

## Documentation

Menu-path usage docs live in `docs/usage/`. The Forgejo wiki covers how
NBDE works in this setup, troubleshooting/FAQ, and lessons learned.
Documentation is part of the definition of done for any change, not a
follow-up. The original design spec this project was built from is
kept at `docs/original-spec.md` for reference.
