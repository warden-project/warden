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
- No service restart is needed either way — Tang picks up key changes
  immediately.

**Confirmed on real hardware (Ubuntu 24.04):** the key database
directory is `/var/lib/tang` (owned by `_tang:_tang`, mode 750), not
`/var/db/tang` as upstream's own documentation examples use —
`tangd@.service`'s `ExecStart` was checked directly to confirm this.
Overridable via `WARDEN_TANG_DB_DIR` if it differs on a given host.

**Rotation mechanism:** Warden first looks for the bundled
`tangd-rotate-keys` helper (candidate paths
`/usr/libexec/tangd-rotate-keys` and `/usr/lib/tangd/tangd-rotate-keys`,
then a `PATH` lookup as a last resort — overridable via
`WARDEN_TANGD_ROTATE_KEYS_CANDIDATES`, space separated). This script
*is* shipped on Ubuntu, but by the `tang-common` package (a dependency
of `tang`), not by `tang` itself — `dpkg -L tang` alone won't show it.

If no script is found anywhere, Warden falls back to the same
procedure documented in `man tang`'s KEY ROTATION section, reimplemented
directly: generate a new ES512 (signing) key and a new ECMR (exchange)
key via `jose jwk gen`, matching ownership/permissions to the existing
key directory, then hide (rename with a leading dot) whatever keys were
previously visible. This fallback was cross-checked line-by-line
against the real `tangd-rotate-keys` script and implements the same
steps, so it's kept as a genuine fallback (defense-in-depth) rather
than a stopgap, even though the real script is expected to be present
on any standard `tang` install.
