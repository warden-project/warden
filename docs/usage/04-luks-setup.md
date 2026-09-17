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
4. Asks which filesystem to create (default `ext4`).
5. Supports a dry-run preview, like every other wizard.
6. Runs `cryptsetup luksFormat`, opens the device to create the
   filesystem, then closes it again.
7. Hands off directly into the same enrolment logic menu 5 uses —
   mapper name, mountpoint, crypttab/fstab, Clevis bind, test-unlock —
   using the UUID just created and the passphrase just set, so you
   don't re-enter either.

The recovery passphrase is piped to `cryptsetup` on stdin, never passed
as a command-line argument or written to the session log — only the
fact that a passphrase was set is logged.
