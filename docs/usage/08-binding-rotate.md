# Menu 8 — Add / remove / rotate a binding

For a device that's already enrolled. Shows current bindings before
offering any action — you never have to remember or type a slot number
by hand; Warden looks them up and displays them.

- **Add a new binding** — binds the current trust configuration (menu
  3) into a fresh slot alongside whatever's already there.
- **Remove an existing binding** — picks a slot from the displayed
  list and unbinds it. If it's the device's only binding, warns
  explicitly that removing it disables automatic unlock entirely, and
  either way asks you to confirm you have the recovery passphrase (or
  another working binding) in hand first.
- **Rotate** — the safe pattern for replacing a binding:
  1. Binds the current trust configuration into a fresh slot.
  2. Test-unlocks using that new slot specifically, to prove it
     actually works. For a ZFS-backed device (an enabled
     `warden-zfs-import@<mapper>.service` unit), this uses the same
     export/close/reopen/reimport dance as menus 4/5's enrolment
     wizard, since the device is already open under its real mapper
     name and cryptsetup refuses a second mapping of it.
  3. **Only if that verification succeeds**, offers to remove the old
     slot(s). If verification fails, the old binding is left
     completely untouched and the device can still unlock exactly as
     it did before — rotation never trades a working binding for a
     broken one.

All three actions require the device's existing LUKS passphrase, since
Clevis needs an existing key to authorise adding a new one.

## Removal is limited to Clevis-managed slots, structurally

Only bindings visible to `clevis luks list` (i.e. keyslots with a
Clevis token attached) are ever shown as removable — a bare recovery
passphrase or keyfile slot has no such token and simply never appears
in that list. On top of that, before ever running `clevis luks
unbind`, Warden independently re-checks the target slot against
`cryptsetup luksDump`'s own token metadata (a second, separate source
from `clevis luks list`) and refuses outright if that slot doesn't
have a Clevis token attached. This applies to both the Remove action
and the old-slot cleanup step of Rotate. In practice this refusal
should be unreachable — the two safeguards are independent by
design, so a display bug or Clevis version quirk in one can't quietly
let a passphrase/keyfile slot slip through the other.
