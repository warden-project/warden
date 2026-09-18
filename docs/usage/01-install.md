# Menu 1 — Install components

Installs Tang, Clevis, or both. Shows current install status for every
package this menu manages first, then a plain-language reminder of
what each component does, before asking what to install.

- **Tang only** — installs `tang`.
- **Clevis only** — installs `clevis clevis-luks clevis-systemd` (all
  three, every time — `clevis-systemd` being silently missed is a
  confirmed past incident; see the wiki's Lessons Learned page).
- **Both** — both of the above.
- Optionally offers `clevis-tpm2` (TPM2 pin support) when Clevis is
  selected, with a one-line note that PCR-sealed bindings can break
  after firmware/kernel updates.
- Optionally offers `zfsutils-linux` when Clevis is selected, letting
  menus 4/5 create or enrol a device as a single-disk ZFS pool.
- Confirms Ubuntu's `universe` archive is enabled first, enabling it if
  not.
- Every install check is idempotent: already-installed packages are
  skipped, not reinstalled.
- Offers a dry-run preview before actually installing anything.

`clevis-initramfs` (root-drive unlock) is deliberately **not** offered
here. It needs its own guided wizard with extra safeguards that doesn't
exist yet — see the wiki for the current manual, guide-only procedure
if you need it now.
