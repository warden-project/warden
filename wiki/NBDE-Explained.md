# How NBDE works here

This page explains the mechanism Warden automates, for anyone who
doesn't already live in this stack.

## The pieces

- **LUKS** encrypts a block device. Unlocking it needs a key that lives
  in one of a small number of key "slots" in the LUKS header. A
  passphrase is one way to fill a slot; Clevis binding is another.
- **Tang** is a server that answers key-exchange requests. It holds no
  list of clients and does no authentication — anything that can reach
  it on the network can complete an exchange. The security model is
  "can this host reach Tang at boot time," not "is this host
  authorized."
- **Clevis** is the client. `clevis luks bind` wraps a LUKS key in a
  "pin" — a small policy describing how to recover it later (contact
  this Tang server, satisfy this many of these N pins, unseal this
  TPM2 PCR state) — and stores that pin, encrypted, in a LUKS token
  slot. No secret is stored in the pin itself; recovering the key
  requires actually completing the exchange the pin describes.

## Boot-time unlock, end to end

1. `/etc/crypttab` has a line for the device:
   `<mapper-name> UUID=<uuid> none luks,_netdev`. The `none` means "no
   fixed keyfile — something else will provide the key," and
   `_netdev` tells systemd this device depends on the network being
   up before it can be unlocked.
2. `/etc/fstab` has the matching mount entry pointing at
   `/dev/mapper/<mapper-name>`, so once the mapper device exists,
   normal mounting takes over.
3. `clevis-systemd` provides `clevis-luks-askpass.path`, which watches
   for systemd's password-agent socket appearing for a LUKS device and
   answers it automatically by running `clevis luks unlock`, rather
   than a human being asked to type a passphrase.
4. `clevis luks unlock` reads the bound pin(s) from the LUKS header,
   performs the described exchange (contact Tang, unseal TPM2, or
   both under an SSS threshold), recovers the wrapped key, and unlocks
   the device — all without a human present.

This is why `clevis-systemd` being missing is a *silent* failure: the
LUKS device, the crypttab entry, and the Clevis binding can all be
completely correct, and boot will still hang waiting for a passphrase
that will never come, because nothing was listening to answer it
automatically. See [[Lessons Learned]].

## SSS (Shamir's Secret Sharing) pins

When a binding uses more than one pin (e.g. two Tang servers, or a Tang
server plus TPM2), Clevis wraps the key with an `sss` pin containing a
threshold `t` and the list of child pins. "Any 1 of 2" (`t=1`) means
either pin alone can recover the key; "both required" (`t=2`) means
both must succeed. See [[Lessons Learned]] for the multi-pin timeout
behaviour to expect when one of the pins is unreachable.

## Tailscale ordering

`network-online.target` only guarantees basic networking is up, not
that Tailscale has finished connecting and the tailnet is reachable.
Ordering purely against `tailscaled.service` isn't reliable either — the
service can be running before the tailnet handshake completes. Warden
adds a drop-in ordering the relevant
`systemd-cryptsetup@<name>.service` unit after
`tailscale-online.target` when a bound Tang address is on the tailnet,
so boot-time unlock actually waits for the tailnet to be usable.
