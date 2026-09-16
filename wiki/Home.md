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

Phase 0 (scaffolding: safety primitives, menu shell, CI) is complete.
See the repository README for the phase roadmap.

## Scope

Ubuntu Server hosts only. The Tang server on the Unraid NAS (Docker
container) is managed through Unraid's own UI and is explicitly out of
scope for this tool.
