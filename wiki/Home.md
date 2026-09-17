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

Phase 5 is under way: every menu except Uninstall/revert (12) is now
implemented -- install (1), Tang server config (2), Tang
bindings/SSS/Tailscale (3), LUKS setup (4), LUKS enrolment (5), the
late-boot unlocker (6), the status dashboard (7), add/remove/rotate a
binding (8), LUKS header backup (9), Tang server key rotation (10),
and the Danger Zone's cryptographic erase (11). Menus 4, 5, and 11
route through the same destructive-confirmation guard built in
Phase 0 (lsblk display, root/boot/efi refusal with a typed override,
then a typed `<ACTION> <fragment>` confirmation) -- 11 additionally
wraps the whole flow in the Danger Zone's distinct visual banner, and
uses the harder `ERASE <fragment>` bar for the single most
irreversible action in the tool. Menu 8's rotate action uses the same
bind-verify-then-unbind sequencing so a binding is never replaced with
an unproven one.

Uninstall/revert (menu 12) is the one remaining piece, and must be
structurally unreachable from the Danger Zone's erase flow, not just
conventionally separate. Root-drive unlock (`clevis-initramfs`)
remains deliberately deferred -- see [[Lessons Learned]]. See the
repository README for the phase roadmap.

## Scope

Ubuntu Server hosts only. The Tang server on the Unraid NAS (Docker
container) is managed through Unraid's own UI and is explicitly out of
scope for this tool.
