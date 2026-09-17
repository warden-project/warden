# Menu 12 — Uninstall / revert

Granular, not all-or-nothing — each action below is independent and
picking one doesn't touch the others. **Never** touches actual
LUKS-encrypted data; that's exclusively the Danger Zone's job (menu
11), and the two menus share no code path at all — see the comment at
the top of `lib/features/uninstall.sh`.

- **Disable the late-boot unlocker only** — shows current status,
  disables and stops `clevis-luks-askpass.path`. Reverts every device
  to manual (passphrase) unlock at boot; leaves bindings and packages
  alone.
- **Unbind Clevis from a device** — shows current bindings, then
  requires confirming you have that device's recovery passphrase in
  hand before removing every Clevis binding on it (this is the point
  of no return for automatic unlocking on that specific device). Uses
  the same hard non-Clevis-slot gate as menu 8, so it's just as
  incapable of touching a bare passphrase or keyfile slot.
- **Remove Warden-added systemd drop-ins** — lists existing Tailscale
  ordering drop-ins, backs up and removes the chosen one. Only removes
  the ordering hint; the device still auto-unlocks, just without
  specifically waiting for Tailscale.
- **Uninstall packages** — shows current install status, then removes
  Tang, Clevis, clevis-tpm2, or everything, in dependency-safe order
  (dependents before the base package). Doesn't touch crypttab/fstab,
  bindings, or LUKS data.
