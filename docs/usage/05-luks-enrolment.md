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
3. Asks for the device's **existing** LUKS passphrase first — a closed
   LUKS device gives no visibility into what's actually inside it,
   which the next step depends on. This is written to a mode-600
   temporary file, passed to `clevis luks bind -k`, and shredded
   immediately after — never passed as a command-line argument or
   logged.
4. If `zfsutils-linux` is installed (menu 1, optional), opens the
   device under a throwaway probe name to check whether it's already a
   ZFS pool member:
   - **If it is:** discovers the pool's real name (which may differ
     from whatever mapper name it was originally created under, or
     even come from a different host), refuses cleanly if that name
     can't also be used as the crypttab mapper name (letters, numbers,
     `-`, `_` only, and not already in use — this design reuses one
     name for both), then reopens the device under that name, imports
     the pool, and continues using its actual current mountpoint — no
     mountpoint/fstype prompts, and no `/etc/fstab` entry (ZFS doesn't
     use one). Enables a `warden-zfs-import@<mapper>.service` unit
     (see menu 4) so it auto-imports/mounts at boot from here on.
   - **If it isn't** (or `zfsutils-linux` isn't installed): continues
     with the plain-filesystem flow below exactly as before.
5. (Plain filesystem only) Asks for a mapper name (showing existing
   names on the system for context), a mountpoint (or `none` to skip
   the fstab entry), and — if a mountpoint was given — the filesystem
   type.
6. Shows a preview of the exact crypttab/fstab lines and a summary of
   the trust configuration it's about to bind against (pin type,
   threshold, every address) — not just that a config exists, but
   what's actually in it — with the usual dry-run option.
7. Backs up crypttab/fstab before appending (never regenerated
   wholesale), binds Clevis using the saved trust configuration, then
   immediately does a test-unlock into a throwaway mapper name and
   cleans it up — so you find out now whether it actually works,
   rather than at the next reboot. For a ZFS-backed device, this
   involves a brief export/close/reopen/reimport dance instead of a
   simple second mapping, since the device is already open under its
   real name by this point (see the wiki's
   [Lessons Learned](https://github.com/warden-project/warden/wiki/Lessons-Learned)
   page).
8. If any address in the trust configuration is Tailscale-flagged,
   also adds a `systemd-cryptsetup@<mapper>.service.d` drop-in ordering
   this device's unlock after `tailscale-online.target` — idempotent,
   backed up before any change, using the properly systemd-escaped
   unit name for the mapper. See the wiki's "Tailscale ordering gap"
   entry in [Lessons Learned](https://github.com/warden-project/warden/wiki/Lessons-Learned)
   for why this matters: `network-online.target` alone doesn't
   guarantee the tailnet is actually reachable yet.
