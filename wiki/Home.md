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

Phase 2 is complete: install (menu 1), Tang server config (menu 2),
Tang bindings/SSS/Tailscale (menu 3), and the status dashboard
(menu 7) are all implemented, on top of the Phase 0 safety primitives
(logging, dry-run execution, the root/boot/EFI guard, typed
confirmation, backup-before-edit). Everything from menu 4 onward (the
LUKS wizards, maintenance, and the Danger Zone) is not yet built. See
the repository README for the phase roadmap.

## Scope

Ubuntu Server hosts only. The Tang server on the Unraid NAS (Docker
container) is managed through Unraid's own UI and is explicitly out of
scope for this tool.
