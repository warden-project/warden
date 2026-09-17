# Menu 6 — Enable/verify late-boot unlocker

Verifies `clevis-systemd` is actually installed before doing anything
else — this exact gap (installed `clevis`/`clevis-luks` but not
`clevis-systemd`) is a confirmed past incident that silently broke
boot-time unlock while everything else looked correct. See the wiki's
Lessons Learned page.

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
