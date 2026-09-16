# Menu 2 — Configure Tang server

Only available once Tang is installed (menu 1). Configures the local
`tangd.socket` unit:

- Asks for a port (suggests `80`, but any valid port 1-65535 is
  accepted).
- Writes the port as a `[Socket]` drop-in at
  `/etc/systemd/system/tangd.socket.d/override.conf` — the same result
  `systemctl edit tangd.socket` would produce, but as a plain file
  write so it logs and diffs like everything else Warden touches,
  rather than shelling out to an interactive editor. `ListenStream=` is
  cleared before being set, matching the pattern systemd expects for
  socket drop-ins.
- Idempotent: re-running with the same port is a no-op; changing the
  port backs up the existing drop-in first.
- Enables and starts `tangd.socket` (both idempotent — skipped if
  already enabled/active).
- If `ufw` is active, offers to allow the chosen port through it.
- Verifies with a local `curl http://localhost:<port>/adv` and reports
  success or failure clearly — it does not just assume the config
  applied cleanly.
- Reminds you that `/var/db/tang/` needs backing up outside this tool.
  Warden won't do this automatically; where you back it up to (so that
  the encrypted drive's own failure wouldn't also take out the backup)
  is your call.

Supports a dry-run preview before committing, like every other wizard.
