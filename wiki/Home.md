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

Phase 3 is complete: every Day 0/Day 1 menu item is implemented --
install (1), Tang server config (2), Tang bindings/SSS/Tailscale (3),
LUKS setup (4), LUKS enrolment (5), the late-boot unlocker (6), and the
status dashboard (7). Menus 4 and 5 are the first paths that actually
touch disk encryption state, and both route through the same
destructive-confirmation guard built in Phase 0 (lsblk display,
root/boot/efi refusal with a typed override, then a typed
`<ACTION> <fragment>` confirmation).

Maintenance (menus 8-10), the Danger Zone (menu 11), and
uninstall/revert (menu 12) are not yet built. Root-drive unlock
(`clevis-initramfs`) remains deliberately deferred -- see
[[Lessons Learned]]. See the repository README for the phase roadmap.

## Scope

Ubuntu Server hosts only. The Tang server on the Unraid NAS (Docker
container) is managed through Unraid's own UI and is explicitly out of
scope for this tool.
