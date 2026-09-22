# Menu 13 — Uninstall / revert (5 independent actions)

Granular, not all-or-nothing — each action below is independent and
picking one doesn't touch the others. **Never** touches actual
LUKS-encrypted data; that's exclusively the Danger Zone's job (menu
14), and the two menus share no code path at all — see the comment at
the top of `lib/features/uninstall.sh`.

- **Disable the late-boot unlocker only** — shows current status,
  disables and stops `clevis-luks-askpass.path`. Reverts every device
  to manual (passphrase) unlock at boot; leaves bindings and packages
  alone.
- **Unbind Clevis from a device** — shows current bindings, then
  requires confirming you have that device's recovery passphrase in
  hand before removing every Clevis binding on it (this is the point
  of no return for automatic unlocking on that specific device). Uses
  the same hard non-Clevis-slot gate as menu 10, so it's just as
  incapable of touching a bare passphrase or keyfile slot.
- **Remove crypttab/fstab entries for a device** — shows the device's
  mapper, UUID, and current Clevis bindings, then removes its
  `/etc/crypttab` (and `/etc/fstab`, if present) entries only. Doesn't
  touch the LUKS header, keyslots, or any Clevis binding. This is the
  action to use once a device is done being managed by Warden — most
  importantly right after a Danger Zone erase (menu 14): with every
  keyslot destroyed, that device can never unlock again, and its
  crypttab entry has no `nofail` option, so leaving it in place risks
  hanging the next boot waiting on it. "Unbind Clevis from a device"
  above doesn't help in that case, since it reverts to manual
  passphrase unlock — which assumes a working passphrase keyslot still
  exists. If the device has a `warden-zfs-import@<mapper>.service`
  unit enabled (menu 4's ZFS path), this also exports the zpool (if
  currently imported) and disables that unit — the pool and its data
  are left completely intact and can still be re-imported manually
  later if needed; only the automatic boot-time behaviour is removed.
- **Remove Warden-added systemd drop-ins** — lists existing Tailscale
  ordering drop-ins, backs up and removes the chosen one. Only removes
  the ordering hint; the device still auto-unlocks, just without
  specifically waiting for Tailscale.
- **Uninstall packages** — shows current install status, then removes
  Tang, Clevis, clevis-tpm2, or everything, in dependency-safe order
  (dependents before the base package). Doesn't touch crypttab/fstab,
  bindings, or LUKS data.
