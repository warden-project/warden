# Menu 2 — Configure Tang server

Only available once Tang is installed (menu 1). Configures the local
`tangd.socket` unit:

- Shows current status first: configured port, whether the unit is
  enabled/active, and ufw's rule state if ufw is active.
- Asks for a port, defaulting to whatever's actually configured right
  now (not a hardcoded suggestion) — any valid port 1-65535 is
  accepted.
- Writes the port as a `[Socket]` drop-in at
  `/etc/systemd/system/tangd.socket.d/override.conf` — the same result
  `systemctl edit tangd.socket` would produce, but as a plain file
  write so it logs and diffs like everything else Warden touches,
  rather than shelling out to an interactive editor. `ListenStream=` is
  cleared before being set, matching the pattern systemd expects for
  socket drop-ins.
- Idempotent: re-running with the same port is a no-op; changing the
  port backs up the existing drop-in first.
- Enables `tangd.socket` (idempotent — skipped if already enabled).
  If it was already active (e.g. it's enabled by default on install),
  it's explicitly **restarted** rather than left alone — confirmed on
  real hardware that a running socket unit does not pick up a changed
  port from a drop-in + `daemon-reload` alone; systemd itself flags it
  non-functional until restarted. If it wasn't running yet, it's
  simply started.
- If `ufw` is active, offers to allow the chosen port through it.
- Verifies with a local `curl http://localhost:<port>/adv` and reports
  success or failure clearly — it does not just assume the config
  applied cleanly.
- Reminds you that `/var/lib/tang/` (Ubuntu's real key database
  directory, confirmed against `tangd@.service`'s own `ExecStart` —
  not `/var/db/tang`, the path used in upstream's own documentation
  examples) needs backing up outside this tool. Warden won't do this
  automatically; where you back it up to (so that the encrypted
  drive's own failure wouldn't also take out the backup) is your call.

Supports a dry-run preview before committing, like every other wizard.
