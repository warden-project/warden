# Warden wiki

Warden is a TUI for managing Network-Bound Disk Encryption (NBDE) —
Tang and Clevis — on Ubuntu Server hosts.

- [[NBDE Explained]] — how crypttab, fstab, and the late-boot unlocker
  actually fit together, written for future reference rather than
  assuming prior NBDE knowledge.
- [[Troubleshooting FAQ]]
- [[Lessons Learned]] — the real incidents and upstream gotchas that
  shaped Warden's safety design.

## Status

All twelve menu items are implemented: install (1), Tang server
config (2), Tang bindings/SSS/Tailscale (3), LUKS setup (4), LUKS
enrolment (5), the late-boot unlocker (6), the status dashboard (7),
add/remove/rotate a binding (8), LUKS header backup (9), Tang server
key rotation (10), the Danger Zone's cryptographic erase (11), and
uninstall/revert (12).

Menus 4, 5, and 11 route through the same destructive-confirmation
guard built in Phase 0 (lsblk display, root/boot/efi refusal with a
typed override, then a typed `<ACTION> <fragment>` confirmation) -- 11
additionally wraps the whole flow in the Danger Zone's distinct visual
banner, and is the single most irreversible action in the tool. Menu
8's rotate action uses the same bind-verify-then-unbind sequencing so
a binding is never replaced with an unproven one; menu 12's
device-unbind action shares that same hard non-Clevis-slot gate, so
neither can touch a bare passphrase or keyfile slot. Menu 12 shares no
code path with menu 11 at all -- checked directly, not just assumed --
so uninstalling can never reach the erase flow.

Root-drive unlock (`clevis-initramfs`) remains deliberately deferred,
to be revisited as its own separate decision later -- see
[[Lessons Learned]]. See the repository README for more.

## Scope

Ubuntu Server hosts only. The Tang server on the Unraid NAS (Docker
container) is managed through Unraid's own UI and is explicitly out of
scope for this tool.
