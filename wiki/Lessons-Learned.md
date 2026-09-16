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

## Tailscale ordering gap

`network-online.target` means basic networking is up, not that
Tailscale has finished connecting — and ordering purely against
`tailscaled.service` isn't reliable either, since the service can be
running before the tailnet handshake completes. A Clevis unlock attempt
against a Tailscale-only Tang address can therefore run before the
tailnet is actually usable. Warden adds a `tailscale-online.target`
ordering drop-in on the relevant `systemd-cryptsetup@` unit whenever a
bound address is confirmed to be on the tailnet. See [[NBDE Explained]].
