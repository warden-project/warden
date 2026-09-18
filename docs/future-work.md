# Future work (not yet scoped or scheduled)

Ideas raised during development that are deliberately not part of the
current implementation, kept here so they aren't lost. Nothing in this
file is committed to — it's a starting point for scoping conversation
whenever picked up.

## Root-drive unlock (`clevis-initramfs`)

Already noted as deferred, high-risk, separate scope in
[`original-spec.md`](original-spec.md) (see "Root-drive unlock" there
for the specific extra warnings it would need). Not repeated here in
full — that document is the source of truth for this one.

## ZFS pool/dataset support

Raised 2026-09-18: extend Warden so a device can be a ZFS pool member
instead of holding a plain filesystem (ext4/etc.) directly inside
LUKS, with automatic mounting after unlock functionally equivalent to
what menus 4/5 already do for a plain filesystem.

**Decided:** single-disk pools only for the first version (one LUKS
device = one zpool, matching the existing 1:1 device model exactly —
no mirror/raidz, no multi-device pickers). Fits into menus 4/5 as a
filesystem-type choice alongside ext4/etc., not a separate menu.

**Status: menu 1 (install) and menu 4 (new device) are done, and
validated end-to-end through the real TUI on real hardware, including
a full reboot proving auto-unlock → auto-import → auto-mount with no
manual intervention.** Menu 5 (enrol an *existing* ZFS-backed device),
menu 7 (status dashboard), and menu 12 (uninstall) ZFS-awareness are
not started — see "Remaining scope" below.

**Architecture below is validated against real hardware** (Ubuntu
24.04 VM, real reboots, not just read from docs) — see the wiki's
Lessons Learned page for the three real bugs this testing found and
fixed along the way: a pre-existing, ZFS-unrelated boot-unlock gap for
any "no mountpoint" device, a genuine systemd ordering-cycle trap in
the first ZFS-ordering approach tried, and cryptsetup refusing a
second mapping of an already-open device during the enrolment
wizard's own test-unlock step.

### What changes at enrolment time

- Menu 4/5's filesystem-type prompt gets a `zfs` option. When chosen,
  skip `mkfs.<fstype>` entirely and instead:
  `zpool create -m <mountpoint> <mapper> /dev/mapper/<mapper>` — this
  both creates the pool AND its default top-level dataset, mounted at
  the given mountpoint, in one command. Reuse the mapper name as the
  zpool name (one prompt, not two) — needs a new `is_valid_zpool_name`
  check layered on top of the existing mapper-name validation, since
  zpool names disallow a few reserved words (`mirror`, `raidz`, `log`,
  `cache`, `spare`, a leading digit, `c[0-9]…` patterns) that mapper
  names don't need to reject.
- No `/etc/fstab` entry at all for a ZFS-backed device — ZFS never
  uses fstab; mounting is driven by the dataset's own `mountpoint`
  property plus a Warden-created systemd unit (below), not fstab.
- `zpool create` updates `/etc/zfs/zpool.cache` automatically — no
  separate cache-management step needed.

### The boot-ordering problem (this is the real crux, and it took three attempts)

**Attempt 1 (wrong):** assumed the stock `zfs-import-cache.service` /
`zfs-import-scan.service` (both ship `After=cryptsetup.target`) would
just work, since Warden's crypttab entries are ordered as part of the
generic crypttab machinery. **Real reboot test showed the pool was
never imported.**

**Root cause, and a second, independent, pre-existing bug:** every
crypttab entry Warden creates has `_netdev` set, which routes its
`systemd-cryptsetup@` unit through `remote-cryptsetup.target` instead
of `cryptsetup.target` — and `remote-cryptsetup.target` is disabled by
default. This isn't ZFS-specific at all: it's why a device enrolled
with mountpoint "none" never unlocked at boot even on the existing
ext4 path (now fixed — see Lessons Learned). Enabling
`remote-cryptsetup.target` (`ensure_systemd_unit_enabled`, already
landed in `complete_enrolment`) is a prerequisite this ZFS work
inherits for free, not something ZFS support needs to solve itself.

**Attempt 2 (wrong):** with the device now correctly unlocking, added
a drop-in ordering `zfs-import-cache.service`/`zfs-import-scan.service`
`After=remote-cryptsetup.target` (or even after the one specific
`systemd-cryptsetup@<mapper>.service` unit). **Both produced a real
systemd ordering-cycle** (`systemd[1]: Found ordering cycle on
remote-cryptsetup.target/start`, job silently deleted to break it) —
because `remote-cryptsetup.target`'s own `After=remote-fs-pre.target`
chain loops back, on a system with `snapd` installed, through
`local-fs.target` → `snapd.mounts.target` → `zfs-mount.service` →
`zfs-import.target` → `zfs-import-cache.service`. Any edge added from
the shared `zfs-import-*` units back toward the `remote-cryptsetup`
family re-enters that loop and systemd silently discards it —
**the fix silently does nothing, with only a journal line to notice.**

**Attempt 3 (works, confirmed via real reboot):** don't touch the
shared `zfs-import-cache.service`/`zfs-import-scan.service` at all.
Instead, per enrolled ZFS device, create and enable a dedicated
template unit that imports and mounts just that one pool, ordered only
against that device's own specific cryptsetup unit — no edges back
into the shared ZFS machinery, so no cycle:

```ini
# /etc/systemd/system/warden-zfs-import@.service
[Unit]
Description=Warden: import ZFS pool %i after its LUKS device unlocks
After=systemd-cryptsetup@%i.service
Requires=systemd-cryptsetup@%i.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/zpool import -N %i
ExecStart=/usr/sbin/zfs mount -a

[Install]
WantedBy=multi-user.target
```

Two details that mattered in testing:
- **Must target `multi-user.target`, not `local-fs.target`.** The
  first version of this unit used `Before=local-fs.target` (to mount
  "as early as possible," matching where ext4 devices mount via
  fstab) and hit the *exact same* ordering-cycle class as attempt 2,
  for the same underlying reason (anything both `After=` a `_netdev`
  cryptsetup unit and `Before=local-fs.target` re-enters the
  network/remote-fs web that loops back through `zfs-mount.service`
  on this system). Mounting later, at `multi-user.target`, avoids it
  entirely. This means a ZFS-backed device's dataset becomes available
  meaningfully later in boot than an fstab-mounted ext4 device would
  — acceptable for a non-root data volume, but worth stating
  explicitly rather than silently accepting.
- The template's `%i` is the mapper name, reused as the pool name
  (per the enrolment-time decision above) — one unit template covers
  every enrolled ZFS device via `systemctl enable
  warden-zfs-import@<mapper>.service`, no per-device unit file
  content to generate, only the enable/disable call.

This confirms the original "needs its own ordering drop-in, analogous
to the Tailscale one" instinct from the first pass at this doc was
directionally right, but the *shape* of the fix (a whole dedicated
per-device unit, not a drop-in on an existing shared unit) only became
clear by hitting the cycle in practice.

### The enrolment wizard's own test-unlock step needed a fourth fix

`complete_enrolment`'s existing test-unlock (shared by menus 4/5)
opens a *second*, throwaway-named mapping of the device to prove
Clevis actually works. For a ZFS device, `create_zfs_pool` has already
opened the device under its *real* mapper name and left the pool
imported there — and real testing showed cryptsetup refuses a second
mapping of the same underlying device outright ("Cannot use device
... which is in use (already mapped or mounted)", exit 5). Every ZFS
enrolment reported "test-unlock failed" despite the bind itself having
succeeded. Fixed with `test_unlock_and_cleanup_zfs`
(`lib/features/luks_enroll.sh`): export the pool and close the real
mapping first, run the normal throwaway-name test-unlock, then reopen
the real mapper and re-import the pool so the operator's session ends
in the same state it would have without the test running at all.

### Remaining scope, not yet validated against real hardware

- Menu 5 (enrol an existing device) needs to detect "this LUKS device
  is already a ZFS pool member" (e.g. via `blkid` reporting
  `zfs_member`) as a distinct case from "already has a filesystem" or
  "blank," and offer to re-enable the `warden-zfs-import@` unit for a
  device that already has a pool on it (e.g. re-enrolling after
  `uninstall`'s "forget" action, or moving a drive between hosts).
- Menu 7 (status dashboard) needs a ZFS-aware branch: `zpool status
  <pool>` (health) and `zfs list -o name,mounted,mountpoint <pool>`
  (dataset mount state) instead of the current crypttab/fstab-based
  checks.
- Menu 12 (uninstall/revert)'s "forget" action (crypttab/fstab-only
  today) needs a ZFS-aware equivalent: `zpool export <pool>` plus
  `systemctl disable --now warden-zfs-import@<pool>.service` and
  removing the unit file, since there's no fstab entry for it to
  clean up.
- Menu 11 (Danger Zone erase) works on the LUKS layer only and needs
  no ZFS-specific change, but its "still has a crypttab entry" boot-
  hang warning (see Lessons Learned) should also check for and mention
  an enabled `warden-zfs-import@<pool>.service` for the erased device.

Revisit menu 5/7/12 as their own follow-up pass — the boot-ordering
design and menu 1/4 are done and real-hardware-validated, but this
remaining integration work hasn't been started or tested yet.
