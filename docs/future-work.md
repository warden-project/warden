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

Why this isn't a drop-in extension of the existing flow — needs actual
design work before implementation:

- Menus 4/5 currently: `cryptsetup luksFormat` → `mkfs.<fstype>` →
  `/etc/crypttab` (unlock) + `/etc/fstab` (mount) entries. ZFS doesn't
  use `/etc/fstab` at all — pools are imported (`zpool import`) and
  datasets mounted via `zfs mount` / `zfs-mount.service`, driven by
  each dataset's own `mountpoint`/`canmount` properties, not fstab.
- The ordering problem is the same *shape* as the existing Tailscale
  ordering drop-in (`ensure_tailscale_ordering_dropin` in
  `lib/features/luks_enroll.sh`) — something needs to run only after
  the specific `systemd-cryptsetup@<mapper>` unit is up — but the unit
  being ordered-after is a zpool import (`zfs-import@<pool>.service`
  or equivalent), not a network target. Likely needs its own
  drop-in/ordering helper, analogous to but distinct from the
  Tailscale one.
- Menu 4 (new device) would need a ZFS path alongside the current
  `mkfs.<fstype>` one: `zpool create` on `/dev/mapper/<mapper>` instead
  of a filesystem, then whatever import/mount wiring the ordering
  design above settles on.
- Menu 5 (enrol an existing device) would need to detect "this LUKS
  device is already a ZFS pool member" as a distinct case from "already
  has a filesystem" or "blank."
- Menu 7 (status dashboard) and menu 12 (uninstall/revert) would need
  ZFS-aware equivalents of their current crypttab/fstab-based checks
  and cleanup.
- Package installation (menu 1) would need `zfsutils-linux` as another
  optional component, following the same explicit-per-package pattern
  as `tpm2` already does (see the project wiki's Lessons Learned page
  on the `clevis-systemd` incident — no inferring one package's
  presence from another's).

Not started. Revisit as its own scoping pass (own architecture-plan
step, own phase) rather than folding into the existing ext4-oriented
enrolment code paths.
