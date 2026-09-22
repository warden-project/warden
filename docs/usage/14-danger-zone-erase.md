# Menu 14 — DANGER ZONE: Erase LUKS header

For secure disposal of a drive (e.g. one that can't reliably be wiped
the normal way). **Not** a routine maintenance action — this is the
single highest-risk action in the tool, and irreversible by design.
Every screen from the explanation onward uses a visually distinct
banner so it never looks like a routine screen.

1. Pick a device from every `crypto_LUKS` device on the system — no
   pre-exclusion; root/boot/efi devices are handled by the same guard
   as everywhere else (see step 3), since a legitimate disposal
   scenario (e.g. a drive that used to be a root disk) shouldn't be
   permanently unreachable from this menu.
2. Explains up front what a cryptographic erase actually does: destroys
   every LUKS key slot and the header, but does **not** overwrite the
   bulk data area — the recognised NIST SP 800-88 Purge-level
   sanitisation technique. Then shows the device's current state in
   full: Clevis bindings *and* the raw `cryptsetup` keyslot inventory
   (not a curated summary).
3. Asks whether a header backup exists somewhere else. This is
   informational only — the answer doesn't block you either way, but
   it's logged, and either answer comes with the reminder that a
   backup would need destroying separately for the erase to actually
   be final.
4. Goes through the same shared destructive-confirmation gate as menus
   4/5 (`confirm_destructive_device_action`): the current `lsblk -f`
   view, refusal-by-default with a full-UUID-typed override if the
   device is or backs root/boot/efi, then typing `ERASE <8-char UUID
   fragment>` to proceed — all rendered with the Danger Zone banner.
5. Supports a dry-run preview, then runs `cryptsetup luksErase
   --batch-mode`.
6. Explains again afterward: key slots and header are gone: data is
   now permanently unrecoverable, even though the bulk data area
   itself was never touched. If the erased device still has a
   `/etc/crypttab` entry, the completion message says so explicitly
   and points to menu 13's "remove crypttab/fstab entries" action —
   with no key slot left, the device can never unlock again, and its
   crypttab entry has no `nofail` option, so leaving it in place risks
   hanging the next boot. If it also has a `warden-zfs-import@`
   unit enabled, that's mentioned too, since the same menu 13 action
   disables it as well.

See the wiki's confirmation-phrase design notes for why `ERASE
<fragment>` was chosen over either a longer typed phrase or a plain
y/n — short enough to not encourage blind copy-paste, but only
derivable by actually reading the device identifier on screen.
