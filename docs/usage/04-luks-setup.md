# Menu 4 — LUKS setup wizard (new device)

For a device that isn't LUKS-encrypted yet. Requires a saved trust
configuration (menu 3) first.

1. Lists candidate devices (anything not already `crypto_LUKS`),
   showing any existing filesystem so you know if there's data on it.
2. Goes through the full destructive-confirmation flow before touching
   anything: shows the current `lsblk -f` view, refuses by default if
   the device is or backs root/boot/efi (with a full-identifier-typed
   override), then requires typing `FORMAT <8-char fragment>` to
   proceed. For a blank device with no UUID yet, the "identifier" is
   the device path itself — that's the only thing that exists to
   confirm against before `luksFormat` creates a UUID.
3. Offers to generate a strong recovery passphrase (shown once, with a
   "save this now" warning, never written to the log) or lets you enter
   your own.
4. If `zfsutils-linux` is installed (menu 1, optional), asks what the
   device should hold: a plain filesystem (default `ext4`, or type any
   `mkfs.<type>`) or a single-disk ZFS pool. If it isn't installed,
   this extra choice is skipped entirely and you go straight to the
   filesystem-type prompt below, exactly as if ZFS support didn't
   exist — no dead-end menu screen for a choice you can't act on.
5. Supports a dry-run preview, like every other wizard.
6. Plain filesystem: runs `cryptsetup luksFormat`, opens the device
   under a throwaway name to create the filesystem, then closes it
   again — the mapper name is asked for afterward. ZFS: runs
   `cryptsetup luksFormat`, then opens the device directly under its
   final mapper name (asked for earlier, since a zpool's name is fixed
   at creation and this reuses the mapper name as the pool name — one
   prompt, not two) and runs `zpool create -m <mountpoint>`, leaving
   the pool imported and mounted immediately.
7. Hands off directly into the same enrolment logic menu 5 uses —
   crypttab, a preview showing the trust configuration it's about to
   bind against, Clevis bind, test-unlock, and (if applicable) the
   Tailscale ordering drop-in — using the UUID just created and the
   passphrase just set, so you don't re-enter either. For ZFS: no
   `/etc/fstab` entry (ZFS doesn't use one) — instead enables a
   per-device `warden-zfs-import@<mapper>.service` unit that imports
   and mounts the pool once the device unlocks at boot. See the wiki's
   Lessons Learned page for why this needed its own dedicated unit
   rather than a drop-in on the shared `zfs-import-*` units (two real
   systemd ordering cycles, found via actual reboot tests).

The recovery passphrase is piped to `cryptsetup` on stdin, never passed
as a command-line argument or written to the session log — only the
fact that a passphrase was set is logged.
