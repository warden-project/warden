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
     actually works.
  3. **Only if that verification succeeds**, offers to remove the old
     slot(s). If verification fails, the old binding is left
     completely untouched and the device can still unlock exactly as
     it did before — rotation never trades a working binding for a
     broken one.

All three actions require the device's existing LUKS passphrase, since
Clevis needs an existing key to authorise adding a new one.
