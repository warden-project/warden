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

Phase 1 is complete: install (menu 1) and the status dashboard
(menu 7) are implemented, on top of the Phase 0 safety primitives
(logging, dry-run execution, the root/boot/EFI guard, typed
confirmation, backup-before-edit). Everything from menu 2 onward
(Tang server config, bindings/SSS/Tailscale, the LUKS wizards,
maintenance, and the Danger Zone) is not yet built. See the repository
README for the phase roadmap.

## Scope

Ubuntu Server hosts only. The Tang server on the Unraid NAS (Docker
container) is managed through Unraid's own UI and is explicitly out of
scope for this tool.
