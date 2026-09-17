# Menu 5 — LUKS enrolment wizard (existing device)

For a `crypto_LUKS` device that already exists (formatted outside
Warden, or previously by menu 4) but isn't managed yet. Requires a
saved trust configuration (menu 3) first.

1. Detects every `crypto_LUKS` device on the system and shows only the
   ones that are **not** already in `/etc/crypttab` — the exact "wait,
   is this already managed?" question this is meant to resolve.
2. Devices that are or back this system's root filesystem, `/boot`, or
   `/boot/efi` are excluded from the list entirely, not just warned
   about. Root-drive unlock is a separate, deferred feature (see the
   wiki) and must never be reachable from this general wizard.
3. Asks for a mapper name (showing existing names on the system for
   context), a mountpoint (or `none` to skip the fstab entry), and — if
   a mountpoint was given — the filesystem type.
4. Asks for the device's **existing** LUKS passphrase, needed to
   authorise adding the new Clevis binding. This is written to a
   mode-600 temporary file, passed to `clevis luks bind -k`, and
   shredded immediately after — never passed as a command-line
   argument or logged.
5. Shows a preview of the exact crypttab/fstab lines and a summary of
   the trust configuration it's about to bind against (pin type,
   threshold, every address) — not just that a config exists, but
   what's actually in it — with the usual dry-run option.
6. Backs up crypttab/fstab before appending (never regenerated
   wholesale), binds Clevis using the saved trust configuration, then
   immediately does a test-unlock into a throwaway mapper name and
   cleans it up — so you find out now whether it actually works,
   rather than at the next reboot.
