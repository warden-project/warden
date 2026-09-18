# Lessons learned

The real incidents and known upstream gotchas that shaped Warden's
safety design. The first two are confirmed incidents; the other two are
documented upstream/systemd behaviour worth knowing about in advance,
not mistakes made in practice.

## The EFI partition near-miss

An EFI boot partition was almost run through `cryptsetup luksFormat` by
mistake, while operating from a wiki page of hand-typed commands. The
operator was confident about the command — just wrong about which
device it was pointed at. A plain "are you sure? y/n" would not have
caught this, because the operator *was* sure.

This is why Warden's root/boot/EFI guard:

- always re-resolves the current root/`/boot`/`/boot/efi` backing
  devices fresh, immediately before a destructive operation — never
  from a cached or earlier-in-session value
- refuses by default, with no override via a simple keystroke
- requires a distinct typed-confirmation step bound to the specific
  device on screen, so the check verifies "did you read what's in front
  of you right now," not "do you feel confident"

## The missing `clevis-systemd` package

`clevis` and `clevis-luks` were installed, but `clevis-systemd` was
not, and the gap was silent. Everything about the binding was correct;
late-boot unlock simply never worked, because nothing was listening for
the password-agent request `clevis luks unlock` needed to answer (see
[[NBDE Explained]]). The mistake was assuming a related package would
"ride in" with the others.

This is why Warden checks every required package explicitly and
individually with `dpkg -s`, never inferring one package's presence
from another's, and why the late-boot-unlocker menu item verifies
`clevis-systemd` specifically before reporting success.

## Multi-pin SSS timeout behaviour

When a binding uses an SSS pin combining a LAN Tang address and a
Tailscale address for the *same* physical Tang server, and one of the
two is unreachable, Clevis does not fail over quickly — the unreachable
pin can take several minutes to time out before falling through to the
one that works. This is documented upstream Clevis behaviour, not a
Warden bug, but it's easy to mistake for a hang if you don't know to
expect it. Warden surfaces this caveat in the binding wizard before the
person commits to that combination.

## Real-hardware testing surfaced a whole bug class the dev sandbox couldn't

The original development sandbox had no root access and lacked
`clevis`/`tang`/`cryptsetup`/`systemd`, so a disposable Ubuntu 24.04
VM was set up specifically to test against real packages. That
testing found several bugs invisible in the sandbox:

- **`set -e` + bare command-substitution assignment silently kills the
  whole program.** `existing="$(some_getter)"` (not inside `if`/`&&`/
  `||`/`while`) propagates `some_getter`'s exit code to the enclosing
  script under `bin/warden`'s `set -euo pipefail`. Several "getter"
  functions used a `[[ -f "$file" ]] && cat "$file"` pattern that
  returns non-zero exit 1 whenever the file legitimately doesn't exist
  yet (a very common, non-error state) — `clevis luks list` on a
  device with zero bindings, or `tailscale status` when Tailscale
  isn't running, behave the same way. Each of these silently crashed
  the entire TUI mid-menu with no error message. Fixed by adding an
  explicit `return 0` after the fallible call in every such getter.
  This bug class is invisible to `bats` by default, since bats test
  bodies never run under `set -e` themselves — the regression tests
  added for this specifically wrap the call in `bash -c "set -euo
  pipefail; ..."` to reproduce the real failure mode.
- **udev/blkid caching lag right after `cryptsetup luksFormat`.** The
  new device's UUID can read back empty for a brief window immediately
  after a successful format (reproduced 5/5 trials). Fixed with an
  explicit `udevadm settle` after every `luksFormat`.
- **`lsblk -r` (raw mode) silently misparses blank disks.** An empty
  FSTYPE column is rendered as two adjacent spaces; naive
  whitespace-split parsing (e.g. plain `awk`) collapses that run and
  shifts every later field left by one, which made every genuinely
  blank candidate disk look like it had an unrecognised type and get
  excluded. Fixed by switching to `lsblk --json` and parsing with
  `python3` instead of hand-rolled field splitting.
- **A systemd socket unit doesn't pick up a config change while
  already active.** Changing tangd's port and doing the idempotent
  "ensure active" dance (`daemon-reload` + start-if-not-active) is a
  no-op if `tangd.socket` was already active from before the change —
  it has to be explicitly `restart`ed to actually rebind on the new
  port.

## Tang key rotation: real path and helper script corrections

Two assumptions made before real-hardware testing turned out to be
wrong:

- The Tang key database directory is `/var/lib/tang` (owned by
  `_tang:_tang`, mode 750) on Ubuntu, not `/var/db/tang` as used in
  upstream's own documentation examples — confirmed directly from
  `tangd@.service`'s `ExecStart`.
- The `tangd-rotate-keys` helper script *is* packaged for Ubuntu, but
  by `tang-common` (a dependency of `tang`), not by `tang` itself —
  checking `dpkg -L tang` alone gives a false negative. The real
  script was read in full and confirmed to implement exactly the
  documented `man tang` KEY ROTATION procedure (new ES512 signing key
  + new ECMR exchange key via `jose jwk gen`, then hide old keys with
  a leading dot rather than deleting them), which validated Warden's
  own from-scratch manual fallback for hosts where the script truly
  can't be found.

## Tailscale ordering gap

`network-online.target` means basic networking is up, not that
Tailscale has finished connecting — and ordering purely against
`tailscaled.service` isn't reliable either, since the service can be
running before the tailnet handshake completes. A Clevis unlock attempt
against a Tailscale-only Tang address can therefore run before the
tailnet is actually usable. Warden adds a `tailscale-online.target`
ordering drop-in on the relevant `systemd-cryptsetup@` unit whenever a
bound address is confirmed to be on the tailnet, applied by the LUKS
setup/enrolment wizards (menus 4/5) once they know which device's
mapper it applies to — see [[NBDE Explained]].
