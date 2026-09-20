# Menu 13 — Root-drive unlock (`clevis-initramfs`)

Automatic unlock of the machine's *own* root filesystem at boot — TPM2
and/or a LAN-only Tang server — instead of only ever prompting for a
passphrase interactively. Structurally separate from menu 8, even
though the underlying primitives are shared: menu 8's device list
(`managed_luks_devices`) deliberately excludes root, so root can never
be reached from the general enrolment/binding menus by accident. There
is no device picker here — there's only ever one root device, resolved
fresh every time.

**Root must already be LUKS-encrypted** (via Ubuntu's installer, at
install time). This enrols Clevis onto an *existing* encrypted root,
exactly like menus 4/5 do for secondary drives — it does not encrypt
an unencrypted root in place.

**Pin types: TPM2 and LAN-only Tang only.** A Tailscale-routed Tang
address can never work for root (`tailscaled` needs the real OS
already running), and neither can a Tang server on this same machine
(it can't start until root is already mounted, which can't happen
until it's unlocked). Both are hard-blocked, not just warned about.

**A Tang pin's reachability check has a real limitation, and the
wizard says so.** Before binding, Enable/Add/Rotate all check the
server is reachable — but that check runs `curl` from this
already-booted OS's full network stack, which on its own proves
nothing about whether `clevis-initramfs`'s own network bring-up can
reach the same server *during the initramfs stage*, before the real OS
(and its network manager) has even started. A "reachable" result here
is a sanity check, not proof the binding will actually work at boot —
only an actual reboot proves that. It has now been proven, at least
for a straightforward single-NIC DHCP LAN (see `docs/future-work.md`
for the real-hardware test: a Tang-only binding, with TPM2 deliberately
removed first so nothing could mask the result, survived a real
reboot without any `ip=` GRUB parameter). A more exotic network setup
(static IP, VLANs, bonded NICs) hasn't been tested and might still
need one.

## The actions

- **Enable** — first-time setup. Refuses if root isn't LUKS-encrypted,
  or if `/boot` isn't its own separate partition (the layout this has
  been verified against). Requires an explicit confirmation that you
  have bootable recovery/rescue media for this machine ready *before*
  anything else happens. Then: pick TPM2 or Tang, install
  `clevis-initramfs`, regenerate the initramfs, and only then bind the
  new pin — in that order, never bind-then-regenerate (see below for
  why). Backs up the pre-change initramfs into a recovery kit first.
- **Add** — bind an additional pin alongside whatever's already there
  (e.g. add a LAN-Tang pin after TPM2 was already enabled). Needs no
  initramfs regeneration: the `clevis-initramfs` boot hook reads
  bindings live off the LUKS header at boot time, not from a baked-in
  image.
- **Remove** — pick a bound slot from the displayed list and unbind
  it. Same hard non-Clevis-slot gate as menu 8: a slot without a
  Clevis token attached (i.e. the passphrase slot) can never be
  touched through this path. Warns explicitly if it's the only
  remaining Clevis binding.
- **Rotate** — bind a new pin first, and only offer to remove the old
  one(s) once the bind call itself has succeeded.
- **Status** — current bindings, plus a drift check: does the on-disk
  initramfs still match the checksum Warden last recorded right after
  Enable or Snapshot actually finished changing it? If something else
  regenerated it since (a kernel update, an unrelated
  `update-initramfs -u` run), says so — this just means the recovery
  kit is stale, not that any binding is at risk: Warden's tpm2 pin
  config (`{}`, no `pcr_bank`/`pcr_ids`) is never PCR-sealed, confirmed
  by decoding a real bound token, so an initramfs content change alone
  can't invalidate it. This is deliberately *not* a comparison against
  the recovery kit's own backup file — that backup is always the image
  from just *before* the change, so it would never match and would
  report drift permanently, even with nothing wrong.
- **Snapshot** — manually refresh the recovery kit (guide + script +
  fresh initramfs backup) *and* the drift-check reference above, on
  demand, independent of any binding change. Use this if Status
  reports drift and you've confirmed it's expected (e.g. after a
  kernel update you triggered yourself).
- **Disable** — full revert: removes every Clevis binding from root
  first (back to passphrase-only), *then* uninstalls
  `clevis-initramfs` and regenerates the initramfs to strip the hook
  out, with its own backup-first step. The LUKS passphrase is never
  removed by any action here, ever. Existing recovery kits are left in
  place, not auto-deleted.

## Unlike every other binding path in Warden: no live test-unlock

Every other enrolment wizard in Warden (menus 4/5/8) proves a new
binding works by actually test-unlocking it before declaring success.
Root's own device can never do this: whenever Warden is running, it is
running *from* the very filesystem it would need to test-unlock, so
`cryptsetup` refuses a second mapping outright ("Cannot use device
... which is in use"). There is no workaround — you cannot unmount a
running system's own root filesystem to test it. Enable, Add, and
Rotate all say so explicitly in their completion messages: a
successful `clevis luks bind` exit code is the only automated signal
available, and an actual reboot is the only real proof. Confirmed
real-hardware validated for the TPM2 path: a genuine reboot correctly
unlocked automatically before the OS itself even started.

## Ordering matters: regenerate the initramfs *before* binding a TPM2 pin

`clevis luks bind ... tpm2 ...` seals against the TPM's *current* PCR
values at bind time. Installing `clevis-initramfs` and running
`update-initramfs -u` changes the initramfs image, which — depending
on the PCR bank in use — can itself be measured into the same PCRs a
TPM2 binding seals against. Binding first and regenerating second
risks the regeneration immediately invalidating the seal it just
created, with no obvious symptom until the next reboot silently falls
back to the passphrase prompt. Enable always installs the hook and
regenerates once *before* binding, for exactly this reason.

## The recovery kit

Before ever changing the boot process, Enable (and Disable, and
Snapshot on demand) generate a recovery kit specific to this machine —
no placeholders, no guesswork:

- A guide (`GUIDE.txt`) and a self-contained restore script
  (`restore.sh`) under `/boot/warden-root-unlock-recovery/<timestamp>/`
  — `/boot` is its own unencrypted partition, reachable even if root
  never unlocks at all.
- The actual initramfs backup itself under
  `/root/warden-root-unlock-recovery/<timestamp>/` — restoring it
  needs write access to `/boot` anyway, so it doesn't need to be
  pre-unlock reachable the way the instructions do.

Both locations keep a `latest` symlink and prune older kits beyond a
retention count of 3 (`WARDEN_ROOT_UNLOCK_RETAIN`), never below 1. The
restore script is fully self-contained — it doesn't depend on Warden's
own code being available — warns if it's being run on a system already
on the target kernel (a sign it's probably already healthy), requires
typed `RESTORE` confirmation, and backs up whatever it's about to
overwrite first. **This directory lives under `/root` and `/boot` on
this machine — keep it safe like a recovery code, and don't let
routine cleanup delete it.**
