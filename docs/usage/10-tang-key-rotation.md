# Menu 10 — Rotate Tang server keys

Only meaningful on a host that runs Tang itself — distinct from menu 8,
which rotates a *client's* binding. If Tang isn't installed here, this
menu says so and stops.

- Shows the current key inventory first (visible/advertised vs.
  hidden/retired) before doing anything.
- Generates new keys and retires the current ones by hiding them
  (never deleting) — old keys are kept specifically so existing client
  bindings keep working. Re-bind clients over time and only clean up
  old keys once nothing depends on them anymore.
- Supports a dry-run preview, like every other wizard.

**Caveat:** this relies on upstream Tang's bundled `tangd-rotate-keys`
helper, expected at `/usr/libexec/tangd-rotate-keys` or
`/usr/lib/tangd/tangd-rotate-keys`, falling back to a `PATH` lookup.
This has not been verified against a real `tang` package install — if
none of those locations has it, Warden says so plainly rather than
guessing at reimplementing key rotation by hand. The candidate paths
are overridable via `WARDEN_TANGD_ROTATE_KEYS_CANDIDATES` (space
separated) if the real path differs once tested on an actual host.
