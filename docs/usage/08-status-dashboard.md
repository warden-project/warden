# Menu 8 — Status dashboard

Read-only. Never changes anything on the system. For every
`crypto_LUKS` device currently visible to the kernel, shows:

- Device path, LUKS UUID
- Whether it has a `/etc/crypttab` entry (mapper name), and either:
  whether the matching `/etc/fstab` entry exists, or — if it has a
  `warden-zfs-import@<mapper>.service` unit instead (a ZFS-backed
  device created via menu 4) — that unit's enabled/active state plus
  `zpool status`/`zfs list` output for the pool (or "pool not
  currently imported" if it isn't right now)
- Whether it's currently unlocked (mapper active)
- Current Clevis binding(s) (`clevis luks list`), if any and if Clevis
  is installed

Then, across all devices:

- Live reachability (and latency) of every Tang server referenced by
  any current binding — this is derived from whatever's actually
  bound right now, not the separately-saved trust configuration from
  menu 3
- `tangd.socket` and `clevis-luks-askpass.path` status, if the
  relevant package is installed
- Any Tailscale-ordering systemd drop-ins currently in place

If a device shows as unmanaged (no crypttab entry) or Clevis bindings
show as "none", that's informational — it's exactly the "wait, is this
already managed?" situation the enrolment wizard (menu 5) exists to
resolve.
