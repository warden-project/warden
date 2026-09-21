# Future work (not yet scoped or scheduled)

Ideas raised during development that are deliberately not part of the
current implementation, kept here so they aren't lost. Nothing in this
file is committed to — it's a starting point for scoping conversation
whenever picked up.

## Root-drive unlock (`clevis-initramfs`)

Designed 2026-09-19. Originally deferred as high-risk, separate scope
in [`original-spec.md`](original-spec.md) ("Root-drive unlock" section
— never remove the original passphrase slot, confirm a recovery path
exists first, never reachable accidentally from the general enrolment
wizard). This section is now the full design; `original-spec.md`
remains the source of the original constraints it must satisfy.

**Status: complete and fully real-hardware validated, 2026-09-20.**
All seven actions (Enable, Add, Remove, Rotate, Status, Snapshot,
Disable) exist in `lib/features/root_unlock.sh`, menu 13 is wired into
`bin/warden`'s main menu (Exit moved to 14), and every single one of
them — not just Enable — has now been driven for real against the
LUKS-root test VM, with real reboots proving the two riskiest claims
(a TPM2-only bind unlocking automatically, and a Tang-only bind doing
the same) and real state inspection (`clevis luks list`, `luksDump`,
package status, initramfs hook files) confirming every other action's
effects match what it claims. TPM2 was confirmed first via an actual
reboot: `clevis luks bind` for a TPM2 pin succeeded following the
install→regenerate→bind sequencing fix below, and on reboot
`systemd-cryptsetup` found the volume "already active" by the time the
real OS started. LAN-Tang was then confirmed independently and
conclusively: Add bound a Tang pin (cross-host, at the first VM's Tang
server), Remove then deleted the TPM2 binding entirely so no fallback
could mask the result, and a reboot with *only* the Tang binding
present came up fully automatically — see "Resolved: LAN-Tang does not
need a GRUB kernel-parameter change" below. The same-host-Tang refusal
was confirmed live against a genuinely running Tang server on the
LUKS-root VM itself, blocked via exact IP, `localhost`, and its own
hostname. Rotate was confirmed live (new binding added and left
alongside the old ones when removal was declined, exactly as
designed). Status's drift check was confirmed against a real,
non-Warden-triggered `update-initramfs -u` run, correctly detecting
drift and clearing it via Snapshot. Disable was confirmed via a full
real revert followed by an actual reboot: the machine came back up at
a plain interactive LUKS passphrase prompt with automatic unlock
completely gone, exactly as before this feature was ever enabled. Four
real bugs were found and fixed along the way — see below and the wiki
for the full account of each.

**A second real bug was found on the very first test run**, more
fundamental than anything ZFS hit: root's LUKS device is *always*
already open/mounted whenever Warden itself is running (Warden runs
from the booted OS on that very device), so the generic
`test_unlock_and_cleanup` used everywhere else in Warden fails every
time with "Cannot use device ... which is in use." Unlike ZFS, there
is no export/close/reopen workaround possible — you cannot unmount a
running system's own root filesystem to test it. Fixed by removing the
live test-unlock attempt entirely for root: `clevis luks bind`'s own
successful exit is the only automated signal available, and Enable's
completion message says so explicitly, making clear this is a weaker
guarantee than every other binding path in Warden gives.

**A third real bug was found live, the moment Status was first run
against the real Enable from the run above**: it reported DRIFT
DETECTED immediately, and permanently — every single time, forever,
not just when something external actually changed the initramfs. Root
cause: the drift check compared the current initramfs directly against
the recovery kit's own backup file, but that backup is deliberately
the *pre-change* image (captured before `install_clevis_initramfs_and_
regenerate` runs, so it can be used to revert), which by definition
never matches the initramfs again once that regeneration has actually
happened. Confirmed on the real VM: the backup taken at bind time was
76.5MB (before `clevis-initramfs` was installed); the live initramfs
immediately after was 83.9MB (clevis's own hooks/binaries baked in) —
different content forever, by design, with nothing wrong at all. Fixed
by decoupling the two: a separate `last-known-good.sha256` reference
file, written only once whatever action actually finished changing the
initramfs (Enable, Snapshot), is what Status now compares against —
never the kit's own necessarily-different backup content.

### Scope decisions

- **Root must already be LUKS-encrypted** (via Ubuntu's installer, at
  install time). This feature enrols Clevis onto an *existing*
  encrypted root, exactly like menus 4/5 do for secondary drives — it
  does not encrypt an unencrypted root in place. That's a categorically
  different, much riskier operation and stays out of scope entirely.
- **Pin types: TPM2 and LAN-only Tang.** A Tailscale-routed Tang
  address can never work for root: `tailscaled` is a full userspace
  daemon that needs the real OS running, which can't happen before
  root is even mounted. Not a reachability nuance — a hard
  impossibility, so it's enforced as a hard block, not a warning.
- **A same-host Tang address is also a hard block, for a sharper
  reason than "unreachable."** If the Tang server this host depends on
  for root-unlock runs *on this same machine*, it's a bootstrapping
  deadlock, not a networking problem: Tang runs as a systemd service,
  which can't start until the real root filesystem is mounted, and
  root can't mount until it's unlocked. This would look perfectly
  configured — bind succeeds, even a post-boot test-unlock succeeds,
  since that runs after the OS is already up — right up until the
  reboot that bricks it. Detected via checking whether a candidate
  Tang address resolves to any of this host's own currently-assigned
  addresses (not just literal `127.0.0.1` — a LAN IP that happens to
  be this host's own counts too), not just a fixed loopback check.
- **New menu 13** (`Root-drive unlock`), Exit moves to 14. Kept fully
  self-contained rather than folded into existing menus, matching the
  spec's requirement that this never be accidentally reachable from
  the general wizard — the same reasoning that already keeps the
  Danger Zone (menu 11) structurally separate from Uninstall (menu 12).

### Menu 13's actions: Enable, Add, Remove, Rotate, Status, Snapshot, Disable

No device picker anywhere in this menu — there's only ever one root
device, resolved fresh each time, never cached, consistent with the
rest of the project's "never trust a stale device reference" rule.

Binding management (Add/Remove/Rotate) can't just delegate to menu 8,
even though a root LUKS device is mechanically identical to any other
once it has bindings: menu 8's device list is already built from
`managed_luks_devices`, which excludes root via the same
`guard_not_system_critical` check menu 5 uses. Reusing menu 8 directly
would reintroduce exactly the "accidentally reachable from the general
wizard" risk the spec warns against. So menu 13 needs its own thin
add/remove/rotate, reusing the underlying `run_clevis_luks_bind` /
`run_clevis_luks_unbind` / hard non-Clevis-slot-gate primitives
internally, but as a structurally distinct entry point — the same
relationship danger_erase.sh already has with uninstall.sh (shares
low-level primitives, shares zero code path at the menu level).

- **Enable** — first-time setup. Resolves the root device fresh,
  refuses if it isn't already LUKS-encrypted, requires an explicit
  recovery-media confirmation ("do you have bootable recovery/rescue
  media for this machine ready right now?") before anything else, then
  pin selection (TPM2, checked present via `/dev/tpm0`/`/dev/tpmrm0`
  rather than assumed; or LAN-Tang, validated against the same-host
  block). See "Ordering matters" below for the critical sequencing
  detail. If already enabled, points at Add/Rotate instead of
  redoing setup.
- **Add** — bind an additional pin alongside whatever's already there
  (e.g. TPM2 now, LAN-Tang added later). Shows current bindings first,
  same "state before action" pattern as menu 8. Since the
  `clevis-initramfs` boot script reads bindings live off the LUKS
  header at boot time rather than baking them into the initramfs
  image, **this needs no initramfs regeneration at all** — a
  meaningfully lower-stakes operation than Enable/Disable. **Cannot
  test-unlock the new slot before declaring success**, for the same
  reason Enable can't (below): root's device is always in use while
  Warden runs. An earlier draft of this design assumed a live
  test-unlock here, written before that limitation was discovered
  against real hardware while building Enable — corrected once the
  same constraint was recognised to apply equally to every action
  here, not just Enable.
- **Remove** / **Rotate** — same shape as menu 8's equivalents, same
  hard gate that structurally prevents ever touching a non-Clevis
  (passphrase) slot. No initramfs regeneration needed here either, for
  the same reason as Add. Rotate cannot live-verify the new binding
  before offering to remove the old one either, for the same reason as
  Add — its confirmation prompt says so explicitly and recommends a
  reboot before removing the old slot(s).
- **Status** — current root binding state, plus a drift check: does
  the on-disk initramfs still match a recorded "last known good"
  checksum, or has something regenerated it since (see "Other
  processes can regenerate initramfs too" below). If a TPM2 pin is in
  use and drift is detected, says so explicitly — an initramfs content
  change is exactly the kind of thing that can silently invalidate a
  PCR-sealed TPM2 binding. **Not** compared against the recovery kit's
  own backup file directly — see the real bug this caused, below.
- **Snapshot** — manually regenerate the recovery kit (guide + script
  + fresh initramfs backup) *and* the drift-check reference, on
  demand, independent of changing anything else. Exists specifically
  for the drift scenario: a stale kit/reference doesn't have to wait
  for the next actual Enable/Disable to get refreshed.
- **Disable** — full revert, not just a package removal: remove every
  Clevis binding from root first (reverting to passphrase-only, same
  hard gate as Remove), *then* uninstall `clevis-initramfs` and
  regenerate to strip the hook out — with its own backup-first step,
  same as Enable. Existing recovery kits from earlier enables are left
  alone, not auto-deleted (they're the operator's own safety net;
  destroying them as a side effect of an unrelated action would be
  wrong, matching how menu 12 already treats everything else
  non-destructively).

### Ordering matters: regenerate the initramfs *before* binding, not after

The one must-fix sequencing detail from the design discussion.
`clevis luks bind ... tpm2 ...` seals against the TPM's *current* PCR
values at bind time. Installing `clevis-initramfs` and running
`update-initramfs -u` changes the initramfs image's content, which —
depending on the PCR bank in use — can itself be measured into the
same PCRs a TPM2 binding seals against. Binding *then* regenerating
would risk the regeneration immediately invalidating the seal it just
created: everything would look correctly configured, and the first
real reboot would silently fall through to the passphrase prompt, with
no obvious explanation why. Enable's actual sequence must be: install
the hook, run `update-initramfs -u` once to reach the initramfs's
final stable state, *then* bind — sealing against PCR values that
won't change again as a direct result of Warden's own actions. Doesn't
matter for Tang, but applying it universally keeps one code path
instead of two. The backup-before-change step still captures the
*pre-regeneration* image, regardless of this reordering.

This is the same TPM2/PCR fragility already acknowledged elsewhere in
the project (menu 1's clevis-tpm2 install prompt: "PCR-sealed bindings
can break after firmware/kernel updates and need a re-bind") — just
more acute here, since Enable's own actions can trigger it on day one
if sequenced wrong, and the consequence for root (silent fallback to
an interactive prompt on what might be a headless/remote box) is more
severe than for a secondary drive.

**Confirmed empirically 2026-09-20: this specific fragility does not
currently apply to any binding Warden itself creates.**
`build_tpm2_pin_config` always passes `{}` to `clevis luks bind` — no
`pcr_bank`/`pcr_ids` — and decoding a real bound token's JWE protected
header on the LUKS-root test VM confirmed the stored config really is
just `{"hash":"sha256","key":"ecc"}`, nothing PCR-related. Without a
PCR policy, the TPM2 pin just wraps the key using the TPM chip itself;
it has nothing to measure the initramfs content against, so there's
nothing for a later `update-initramfs -u` to invalidate. Proven live,
not just reasoned: bound a fresh tpm2 slot via Add, then manually ran
`update-initramfs -u` afterward (the "wrong" order) on purpose, and
Status's drift check (which does compare initramfs content, just for
recovery-kit staleness, not seal validity) showed nothing else broke.
The sequencing rule above is still kept — it costs nothing, and would
matter immediately if `pcr_ids` config support is ever added — but the
risk it was written to prevent turned out to already be moot for
Warden's own defaults, and the drift-check's status message no longer
claims otherwise (see `root_unlock_initramfs_drift_status`'s comment).

### The recovery kit

Generated by Enable (first bind), Disable (revert), and on-demand by
Snapshot. Two real design points came out of discussion, beyond the
already-agreed shape (retention count 3, oldest pruned on creation of
a new one, never below 1 while enabled, size-checked before writing,
explicitly communicated to the user that it lives under `/root`):

- **Split storage, not one location.** `/root` is *inside* the
  encrypted root filesystem. In the worst failure case — the
  initramfs itself won't even build/boot far enough to reach the
  normal interactive passphrase prompt — instructions stored there are
  stuck behind the very lock they're meant to help recover from. (Not
  fully broken: the passphrase slot is never removed, so a rescue boot
  can always manually `cryptsetup open` and get in from there — but
  requiring someone to already succeed at manual unlock before they
  can read *how* to fix things is backwards.) Ubuntu's standard
  encrypted-install layout keeps `/boot` itself unencrypted
  specifically so GRUB can read it pre-unlock. Split it: the small
  text guide + standalone script go on `/boot` (always reachable, tiny
  footprint, readable even before anything is unlocked); the
  multi-megabyte initramfs backup itself stays under `/root`
  (restoring it requires write access to `/boot` anyway, which is only
  available once root is reachable one way or another, so the backup
  itself doesn't need to be pre-unlock accessible the way the
  *instructions* do). Also avoids piling large binaries onto what's
  often a deliberately small partition.
- **The guide must be honest about staleness.** Every regeneration
  trigger Warden doesn't control (see below) means a kit can be
  correct as of its own timestamp but no longer reflect the current
  system. The guide states this explicitly: "this snapshot reflects
  the system as of `<timestamp>`; if kernel or package updates have
  happened since, restoring it will also undo those" — so a restore
  doesn't surprise anyone with an over-broad rollback.
- **The recovery script is fully self-contained** — no dependency on
  Warden's own `lib/` being sourceable, since it needs to work from a
  rescue environment where the real root filesystem (and Warden's code
  with it) might not be mounted at all. Every value (root UUID, exact
  kernel version, exact backup/target paths) is baked in at generation
  time, nothing computed or guessed at recovery time. Before touching
  anything, it checks whether the system looks *already healthy* (if
  it can run interactively at all, the machine clearly already
  booted), shows current state (running kernel vs. the kernel this
  backup targets, the target file's current size/timestamp), requires
  an explicit typed confirmation, and backs up whatever it's about to
  overwrite first — guarding specifically against being run against a
  currently-healthy install by mistake.

### Other processes can regenerate the initramfs too

Kernel upgrades (routine, automatic under `unattended-upgrades`),
manual `update-initramfs -u` runs for unrelated reasons, and dpkg
triggers fired by *any* package that ships an initramfs hook can all
regenerate the image independent of Warden. None of this threatens
root-unlock actually continuing to work — the clevis hook is
registered at the package level and gets included in every future
regeneration automatically, regardless of what triggered it. What it
threatens is the recovery kit's *honesty*: it's only ever a snapshot
of the moment Warden itself last changed something, so it can silently
go stale relative to what's actually on disk. Addressed by the drift
check in Status (compare current on-disk initramfs against what the
latest kit recorded) and the honest staleness caveat in the guide
text above — deliberately not by silently auto-refreshing on a guess.

### Preconditions to check, not assume

- **`/boot` is its own separate, unencrypted partition** — confirmed
  against a real Ubuntu 24.04 encrypted install (`vda2` → plain
  `ext4` → `/boot`, entirely separate from `vda3`'s `crypto_LUKS`):
  this is Ubuntu's default layout, and it means GRUB never needs to
  decrypt anything itself — it reads the kernel/initrd straight off
  plain `/boot`, and all decryption happens later, inside the already-
  loaded initramfs. An earlier version of this design assumed GRUB
  needed `GRUB_ENABLE_CRYPTODISK=y` configured and treated that as the
  precondition to check; that's wrong for the standard layout and
  would have made Warden refuse a perfectly normal installation.
  `cryptodisk` support is only relevant for the less common case where
  `/boot` itself lives inside the encrypted volume. The actual
  precondition to check is simpler: confirm `/boot` is a separate
  mount from `/` (as it normally is) — and only in the unusual case
  where it *isn't* would `GRUB_ENABLE_CRYPTODISK`/`cryptomount`
  configuration need verifying at all.
- **TPM2 device actually present** (`/dev/tpm0` or `/dev/tpmrm0`)
  before offering the TPM2 pin option at all.
- **Secure Boot / Unified Kernel Image caveat** (lower priority): a
  standard Ubuntu Server 24.04 boot layout (GRUB + shim + separate
  vmlinuz/initrd.img, not a UKI) doesn't sign or verify the initramfs
  itself even under Secure Boot, so this shouldn't block the project's
  stated scope — but worth a one-line precondition note for anyone
  running an unusual setup where initramfs integrity is enforced.

### Resolved: LAN-Tang does not need a GRUB kernel-parameter change

**Answered 2026-09-19 by a conclusive real-hardware test.** The
question was whether `clevis-initramfs`'s automatic DHCP bring-up
reliably works inside the initramfs without an explicit `ip=` kernel
command-line parameter (which would have meant also touching
`GRUB_CMDLINE_LINUX` and running `update-grub` — a step TPM2 never
needs). Tested by using Add to bind a Tang pin (pointed at the first
VM's Tang server, `192.168.86.41:7591` — a genuine cross-host address)
alongside the existing TPM2 pin, then using Remove to delete the TPM2
binding entirely, leaving Tang as the *only* binding on the device —
removing any possibility of a TPM2 fallback masking the result. On
reboot, the machine came back up fully automatically: `uptime` showed
`up 0 min` / a fresh `system boot` timestamp, and `clevis luks list`
confirmed only the Tang slot existed throughout. No console
intervention, no passphrase entry. `clevis-initramfs`'s stock DHCP
bring-up is sufficient on its own, at least for this straightforward
single-NIC DHCP LAN setup (`enp1s0`, no VLANs, no bonding, no static
IP requirement) — LAN-Tang for root can now be treated as equally
solid as TPM2, not merely "supported, pending verification." A static
IP/VLAN/bonded-NIC setup might still need `ip=`/`update-grub` and
hasn't been tested — worth a caveat if this is ever revisited for a
more exotic network topology.

A related false alarm during this same test, worth recording so it
doesn't cause needless alarm again: after the *first* reboot with both
TPM2 and Tang bound (before Remove), the VM appeared to hang —
unreachable for ~8 minutes at both SSH and its previously-known IP.
It had not hung at all: DHCP had simply handed it a new address on
reboot (`.144` → `.146`), and polling continued to target the stale
one. The VM's console the whole time showed a normal login prompt.
Lesson: don't assume "unreachable at the old IP" means "stuck at a
LUKS prompt" — check the console, or reconnect via hostname (a
`ProxyCommand` resolving through the LAN router's own DNS, e.g. `dig
@<gateway> +short <hostname>`, sidesteps this entirely for future
testing, since this router happens to register DHCP client hostnames).

**A fourth real bug, found while testing Disable, turned out to be in
`run_cmd` itself, not in root-unlock's own code — and affects every
mutating command in the whole tool, not just this feature.** Disable's
`clevis luks unbind` call for the tang slot hung indefinitely every
time it was run interactively (via a live whiptail session, whether
through `tmux` or a persistent `ssh -tt` + `pexpect` session), but
completed instantly when the exact same command was run directly over
a plain non-interactive SSH command. Root cause: `run_cmd` never
redirected the invoked command's stdin, so it always inherited
`bin/warden`'s own live, interactive terminal (whiptail requires one).
Something in `clevis luks unbind`'s call chain for a tang-pinned slot
attempts a stdin read — harmless and near-instant when stdin is
already closed/EOF (prints a benign "Nothing to read on input"
notice), but blocks forever waiting for a keypress that will never
come when stdin is a live, open terminal nobody is typing into.
Notably, unbinding a *tpm2* slot earlier in this same testing session
never hit this, so it wasn't obviously a universal risk until it was.
Fixed at the one chokepoint every mutating command already routes
through: `run_cmd` now always redirects the command's stdin from
`/dev/null`, closing this risk everywhere at once rather than only at
the one call site that happened to surface it.

### Testing

Needed a *second* disposable VM, since the first one has a plain
(non-LUKS) root by deliberate original design (root-unlock was out of
scope when it was built) and can't be converted in place. Built and
confirmed 2026-09-19: Ubuntu 24.04 LTS, OVMF-TPM BIOS, LUKS-encrypted
root via the installer's "encrypt this installation" option — `vda3`
→ `crypto_LUKS` → LVM → ext4 root, `/dev/tpm0`/`/dev/tpmrm0` both
present, `/boot` correctly separate/unencrypted (see the precondition
correction above, found from checking this real install directly).
LAN-reachable from the same network as the first VM, so LAN-Tang
testing can point at the first VM's already-running Tang server for a
genuine cross-host case. The first VM's Tang is deliberately kept on a
non-default port (7591, reconfigured via menu 2 itself rather than by
hand, which incidentally re-exercised that menu for real and caught
two unrelated real bugs — see
[Lessons Learned](https://github.com/warden-project/warden/wiki/Lessons-Learned))
at `192.168.86.41`, so
it's ready as the LAN-Tang test target whenever this gets picked up:
point the LUKS-root VM's root-unlock Tang pin at
`192.168.86.41:7591`.

Validation plan: **all done as of 2026-09-20.** TPM2-only Enable with
a real reboot; the LAN-Tang networking question (resolved, see above);
Add against a real cross-host Tang server, confirming it touches
nothing under `/boot` (no initramfs regeneration triggered); Remove
against real slots (including deleting the TPM2 binding to force the
Tang-only test, and cleanly removing a redundant slot after Rotate);
a Tang-only reboot proving the new binding actually works, not just
that the bind call succeeded; the same-host-Tang refusal triggering
live against a genuinely running Tang server on the LUKS-root VM
itself (blocked via exact IP, `localhost`, and its own hostname);
Rotate exercised against real slots, confirming the new binding is
added and the old one(s) genuinely left untouched when removal is
declined; Status's drift check against a real, non-Warden-triggered
`update-initramfs -u` run, correctly detecting drift and clearing it
via Snapshot; and Disable's full revert sequence with a real reboot
afterward, confirming the passphrase-only prompt actually returns with
automatic unlock completely gone.

Not done, and now deliberately deprioritized rather than outstanding:
a deliberate near-miss (corrupt/replace the initramfs some other way)
to further stress-test the backup-and-recover story's standalone
script — the design and unit tests already cover this at the file
level, and every actual mutating action along the way has now been
proven correct against real hardware, so this would mainly be testing
the recovery script in isolation rather than anything Warden itself
still needs proven.

## ZFS pool/dataset support

Raised 2026-09-18: extend Warden so a device can be a ZFS pool member
instead of holding a plain filesystem (ext4/etc.) directly inside
LUKS, with automatic mounting after unlock functionally equivalent to
what menus 4/5 already do for a plain filesystem.

**Decided:** single-disk pools only for the first version (one LUKS
device = one zpool, matching the existing 1:1 device model exactly —
no mirror/raidz, no multi-device pickers). Fits into menus 4/5 as a
filesystem-type choice alongside ext4/etc., not a separate menu.

**Status: all six planned pieces are done** — menu 1 (install), menu 4
(new device), menu 5 (enrol an existing device), menu 7 (status
dashboard), menu 11 (Danger Zone erase completion message), and menu
12 (uninstall "forget" action). Every piece has been validated
end-to-end through the real TUI on real hardware: menu 1/4/5 with full
reboots proving auto-unlock → auto-import → auto-mount with no manual
intervention (menu 5's case additionally proved a pool created under
one mapper name gets correctly re-discovered and re-enrolled under its
own real name after being "forgotten"/moved), and menu 11/12 via real
create-then-forget-then-re-import testing. This feature is complete
for the single-disk-pool scope decided above; multi-disk pools
(mirror/raidz) remain a distinct, larger, not-yet-scoped feature if
ever wanted.

**Architecture below is validated against real hardware** (Ubuntu
24.04 VM, real reboots, not just read from docs) — see the wiki's
[Lessons Learned](https://github.com/warden-project/warden/wiki/Lessons-Learned)
page for the three real bugs this testing found and
fixed along the way: a pre-existing, ZFS-unrelated boot-unlock gap for
any "no mountpoint" device, a genuine systemd ordering-cycle trap in
the first ZFS-ordering approach tried, and cryptsetup refusing a
second mapping of an already-open device during the enrolment
wizard's own test-unlock step.

### What changes at enrolment time

- Menu 4/5's filesystem-type prompt gets a `zfs` option. When chosen,
  skip `mkfs.<fstype>` entirely and instead:
  `zpool create -m <mountpoint> <mapper> /dev/mapper/<mapper>` — this
  both creates the pool AND its default top-level dataset, mounted at
  the given mountpoint, in one command. Reuse the mapper name as the
  zpool name (one prompt, not two) — needs a new `is_valid_zpool_name`
  check layered on top of the existing mapper-name validation, since
  zpool names disallow a few reserved words (`mirror`, `raidz`, `log`,
  `cache`, `spare`, a leading digit, `c[0-9]…` patterns) that mapper
  names don't need to reject.
- No `/etc/fstab` entry at all for a ZFS-backed device — ZFS never
  uses fstab; mounting is driven by the dataset's own `mountpoint`
  property plus a Warden-created systemd unit (below), not fstab.
- `zpool create` updates `/etc/zfs/zpool.cache` automatically — no
  separate cache-management step needed.

### The boot-ordering problem (this is the real crux, and it took three attempts)

**Attempt 1 (wrong):** assumed the stock `zfs-import-cache.service` /
`zfs-import-scan.service` (both ship `After=cryptsetup.target`) would
just work, since Warden's crypttab entries are ordered as part of the
generic crypttab machinery. **Real reboot test showed the pool was
never imported.**

**Root cause, and a second, independent, pre-existing bug:** every
crypttab entry Warden creates has `_netdev` set, which routes its
`systemd-cryptsetup@` unit through `remote-cryptsetup.target` instead
of `cryptsetup.target` — and `remote-cryptsetup.target` is disabled by
default. This isn't ZFS-specific at all: it's why a device enrolled
with mountpoint "none" never unlocked at boot even on the existing
ext4 path (now fixed — see
[Lessons Learned](https://github.com/warden-project/warden/wiki/Lessons-Learned)).
Enabling
`remote-cryptsetup.target` (`ensure_systemd_unit_enabled`, already
landed in `complete_enrolment`) is a prerequisite this ZFS work
inherits for free, not something ZFS support needs to solve itself.

**Attempt 2 (wrong):** with the device now correctly unlocking, added
a drop-in ordering `zfs-import-cache.service`/`zfs-import-scan.service`
`After=remote-cryptsetup.target` (or even after the one specific
`systemd-cryptsetup@<mapper>.service` unit). **Both produced a real
systemd ordering-cycle** (`systemd[1]: Found ordering cycle on
remote-cryptsetup.target/start`, job silently deleted to break it) —
because `remote-cryptsetup.target`'s own `After=remote-fs-pre.target`
chain loops back, on a system with `snapd` installed, through
`local-fs.target` → `snapd.mounts.target` → `zfs-mount.service` →
`zfs-import.target` → `zfs-import-cache.service`. Any edge added from
the shared `zfs-import-*` units back toward the `remote-cryptsetup`
family re-enters that loop and systemd silently discards it —
**the fix silently does nothing, with only a journal line to notice.**

**Attempt 3 (works, confirmed via real reboot):** don't touch the
shared `zfs-import-cache.service`/`zfs-import-scan.service` at all.
Instead, per enrolled ZFS device, create and enable a dedicated
template unit that imports and mounts just that one pool, ordered only
against that device's own specific cryptsetup unit — no edges back
into the shared ZFS machinery, so no cycle:

```ini
# /etc/systemd/system/warden-zfs-import@.service
[Unit]
Description=Warden: import ZFS pool %i after its LUKS device unlocks
After=systemd-cryptsetup@%i.service
Requires=systemd-cryptsetup@%i.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/zpool import -N %i
ExecStart=/usr/sbin/zfs mount -a

[Install]
WantedBy=multi-user.target
```

Two details that mattered in testing:
- **Must target `multi-user.target`, not `local-fs.target`.** The
  first version of this unit used `Before=local-fs.target` (to mount
  "as early as possible," matching where ext4 devices mount via
  fstab) and hit the *exact same* ordering-cycle class as attempt 2,
  for the same underlying reason (anything both `After=` a `_netdev`
  cryptsetup unit and `Before=local-fs.target` re-enters the
  network/remote-fs web that loops back through `zfs-mount.service`
  on this system). Mounting later, at `multi-user.target`, avoids it
  entirely. This means a ZFS-backed device's dataset becomes available
  meaningfully later in boot than an fstab-mounted ext4 device would
  — acceptable for a non-root data volume, but worth stating
  explicitly rather than silently accepting.
- The template's `%i` is the mapper name, reused as the pool name
  (per the enrolment-time decision above) — one unit template covers
  every enrolled ZFS device via `systemctl enable
  warden-zfs-import@<mapper>.service`, no per-device unit file
  content to generate, only the enable/disable call.

This confirms the original "needs its own ordering drop-in, analogous
to the Tailscale one" instinct from the first pass at this doc was
directionally right, but the *shape* of the fix (a whole dedicated
per-device unit, not a drop-in on an existing shared unit) only became
clear by hitting the cycle in practice.

### The enrolment wizard's own test-unlock step needed a fourth fix

`complete_enrolment`'s existing test-unlock (shared by menus 4/5)
opens a *second*, throwaway-named mapping of the device to prove
Clevis actually works. For a ZFS device, `create_zfs_pool` has already
opened the device under its *real* mapper name and left the pool
imported there — and real testing showed cryptsetup refuses a second
mapping of the same underlying device outright ("Cannot use device
... which is in use (already mapped or mounted)", exit 5). Every ZFS
enrolment reported "test-unlock failed" despite the bind itself having
succeeded. Fixed with `test_unlock_and_cleanup_zfs`
(`lib/features/luks_enroll.sh`): export the pool and close the real
mapping first, run the normal throwaway-name test-unlock, then reopen
the real mapper and re-import the pool so the operator's session ends
in the same state it would have without the test running at all.

### Done: menus 11 and 12

- Menu 12 (uninstall/revert)'s "forget" action now checks for an
  enabled `warden-zfs-import@<mapper>.service`, and if present:
  exports the zpool (only if currently imported) and disables the
  unit. Never touches the pool's data (export, not destroy) or the
  LUKS layer at all -- matches this action's existing scope exactly.
- Menu 11 (Danger Zone erase)'s "still has a crypttab entry" boot-hang
  warning now also checks for and mentions an enabled
  `warden-zfs-import@` unit for the erased device, pointing at the
  same menu 12 action above. Plain text, not a function call -- menu
  11 and menu 12 still share zero code path (verified via grep, same
  as before).

Confirmed live on the test VM: created a real ZFS-backed device
through menu 4, ran "forget" through the real TUI, and verified the
unit was disabled and the pool exported (not destroyed) — re-importing
it manually afterward confirmed the data was still fully intact. A
reboot isn't the right test for this action specifically, since its
whole purpose is to make the device stop doing anything automatic at
boot; the create → forget → re-import cycle is the real proof.

### Done: menu 7

`render_status_report` now checks each managed device for an enabled
`warden-zfs-import@<mapper>.service` before falling back to the usual
fstab check: if present, shows that unit's enabled/active state plus
`describe_zfs_pool_status` (`zpool status`/`zfs list`, or "pool not
currently imported" if it isn't right now) instead of an fstab line
that would never apply to a ZFS-backed device anyway.

Confirmed via the real dashboard on the test VM, and it caught two
real bugs bats' stubbed tests hadn't (see the wiki's
[Lessons Learned](https://github.com/warden-project/warden/wiki/Lessons-Learned)
page): `unit_state`'s existence check doesn't work for
template-instantiated unit names, and `zfs list`'s tab-separated
output rendered as visually cramped/misaligned in whiptail's textbox.
Both fixed.

### Done: menu 5

`feature_luks_enrol_menu` now asks for the passphrase before anything
else, opens the device under a throwaway probe name, and checks
`is_zfs_pool_member` (gated on `zfsutils-linux` being installed, same
as menu 4) to decide which enrolment path to take — a closed LUKS
device gives no other way to see what's inside it.

An existing pool's name isn't a free choice the way it is in menu 4
(where a brand-new pool reuses whatever mapper name was just chosen):
it's already fixed, possibly under a different mapper name or even a
different host, and `warden-zfs-import@.service`'s template assumes
mapper name == pool name. `luks_enrol_zfs_flow` discovers the real
name (`discover_unimported_zfs_pool_name`, factored into `zfs_pool.sh`
specifically so it's unit-testable without whiptail) and requires the
mapper name to match it, refusing cleanly if that name collides with
another crypttab entry or isn't valid as one.

Confirmed via a real reboot: created a pool under one mapper name,
exported and closed it, wiped crypttab, then used menu 5's real TUI to
detect and re-enrol it under its own name (different from the
original) — auto-unlock → auto-import → auto-mount all worked with no
manual intervention on the following boot, marker file intact.

ZFS pool support is now complete for the single-disk-pool scope
decided above.

## A single health-check / self-test action

Raised 2026-09-20. **Status: done**, same day — small enough that it
didn't warrant sitting on the backlog. Checking whether everything
Warden has configured was actually still healthy used to mean
visiting several menus by hand: menu 7 for binding/mount state, menu
13's Status for root-unlock drift, with no single place re-verifying
Tang reachability for every *configured* binding at once (menu 7 only
ever showed reachability for servers a currently-bound device already
referenced) or confirming a TPM2 chip was still present with the right
packages installed.

Implemented as `lib/features/health_check.sh` (menu 14, plus
`warden check` non-interactively): walks every managed device and
configured binding and reports PASS/FAIL/WARN for Tang reachability,
TPM2 hardware/package presence (only checked if some binding actually
uses a tpm2 pin), ZFS import units, the late-boot unlocker path, and
root-unlock drift (a WARN, not a FAIL — drift alone never invalidates
a binding). One render function backs both front ends, so there's only
one implementation to keep correct. Deliberately composition, not new
logic — every individual check reuses a primitive menu 7 or menu 13
already had and already tested. No separate quiet mode was added: the
exit code (0 clean, 1 needs attention) is the actionable signal for a
cron job or monitoring check; the full text is there for when you need
to see why.

## Off-host sync for root-unlock recovery kits

Raised 2026-09-20, not yet scoped. Root-unlock's recovery kits
(`docs/usage/13-root-unlock.md`) currently live only on the same
machine they protect — the guide + script on `/boot`, the initramfs
backup under `/root`. That's sufficient for the failure modes the
design targets (a bad Clevis binding, an initramfs regeneration gone
wrong), but if the whole machine is lost (disk failure, theft,
destroyed hardware) the recovery kit is lost with it, right when it
would matter most for reconstructing what was configured.

The idea: an optional step, after a kit is created, to also copy it
(guide + script + initramfs backup) to a configured off-host
destination — scp/rsync to another host, or an object storage target
— so a total loss of the machine doesn't also mean losing the means to
understand or recover its root-unlock configuration. Would need to
think through what's safe to send off-host (the guide/script contain
no secrets and are already described as fine to store openly; the
initramfs backup itself is also not secret) and how credentials for
the destination itself get configured and stored securely by Warden.

## A non-interactive / scriptable mode

Raised 2026-09-20, not yet scoped, and the largest of these three —
closer to a second front-end than a small addition. Every wizard today
is whiptail-driven, meaning Warden can only be operated by a human
sitting at an interactive session. A config-file or flag-driven path
through the same underlying primitives (`run_cmd`, the device
resolution/guard functions, the bind/enrol logic) would let Warden be
driven from provisioning tooling instead — cloud-init, Ansible, Packer
image builds — rather than only ever by hand after the fact.

This would touch a lot of surface area (every wizard currently
prompts, confirms, and previews via whiptail as one integrated flow)
and raises real safety questions of its own: the typed-confirmation
and root/boot/EFI-override mechanisms exist specifically to slow a
human down before a destructive action, and a non-interactive mode
would need its own equally-deliberate equivalent (an explicit
config-level acknowledgement, most likely) rather than silently
skipping that friction. Worth a proper design conversation before
starting, not a small patch.
