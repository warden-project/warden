# Menu 7 — Verify the late-boot unlocker

Verifies `clevis-systemd` is actually installed before doing anything
else — this exact gap (installed `clevis`/`clevis-luks` but not
`clevis-systemd`) is a confirmed past incident that silently broke
boot-time unlock while everything else looked correct. See the wiki's
[Lessons Learned](https://github.com/warden-project/warden/wiki/Lessons-Learned) page.

- If `clevis-systemd` isn't installed, stops and tells you to install
  it from menu 1 — it does not proceed on an assumption.
- Shows the unit's current enabled/active state and asks before
  changing anything, rather than enabling it unconditionally the
  moment you open this menu.
- Enables `clevis-luks-askpass.path` (idempotent — skipped if already
  enabled).
- Reports the unit's actual current state (`active` vs. anything else)
  rather than assuming enabling it means it's running.

Enabling this unit doesn't by itself guarantee any specific device
unlocks at boot — that also depends on the device having a working
Clevis binding (menus 4/5) and its Tang server(s) being reachable at
boot time.

Also enables `remote-cryptsetup.target` (idempotent). Confirmed via an
actual reboot test on real hardware: crypttab's `_netdev` option (used
on every entry menus 4/5 create) routes a device's `systemd-cryptsetup@`
unit exclusively through `remote-cryptsetup.target`, not the plain
`cryptsetup.target` — and that target is disabled by default on Ubuntu.
A device with an fstab entry still unlocked correctly regardless (the
fstab-generator wires a direct dependency onto the specific unit), but
a device enrolled with mountpoint "none" had nothing else to pull that
unit in at all — it silently never even attempted to unlock, no error
anywhere. Menus 4/5 now enable this target unconditionally at
enrolment time; this menu re-asserts it for anything enrolled before
that fix landed.
