# Menu 11 — Backup LUKS header(s)

Shows any existing backups already taken for the chosen device before
asking whether to make another, so you're not guessing whether this
has been done before.

- Writes to a dedicated directory
  (`/var/backups/warden/luks-headers/` by default), named
  `<uuid>.<timestamp>.header`, mode 600.
- Supports a dry-run preview, like every other wizard.
- Reminds you — in the UI itself, not just here — that a header backup
  contains wrapped key material and is sensitive: store it somewhere
  the encrypted drive's own failure wouldn't also take out the backup.
  Warden does not copy it anywhere else automatically; where it ends up
  long-term is your call.
