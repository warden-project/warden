# Menu 3 — Tang servers to trust (bindings)

Builds and saves the pin configuration that the LUKS enrolment wizard
(menu 5) binds devices against. This is a Day-0 "what do we trust and
how" step, separate from binding any specific device.

## Flow

0. Shows the currently saved trust configuration first, if one exists
   (pin type, threshold, and every address with its Tailscale flag), and
   asks whether to replace it before doing anything else. If nothing is
   saved yet, says so plainly rather than launching straight into the
   wizard with no indication of current state.
1. If Tang is installed and running on this host, offers to include it
   (`127.0.0.1:<configured port>`) as a trusted server.
2. Prompts for further `host:port` addresses, one at a time, until you
   leave the prompt blank. Duplicates are removed automatically.
3. For each address, checks whether it's a Tailscale address:
   - **If the `tailscale` CLI is present**: runs `tailscale status
     --json` and checks whether the host matches a known peer's
     Tailscale IP, DNS name, or hostname. This is treated as
     confirmed.
   - **If the CLI isn't available**: falls back to flagging addresses
     in the `100.64.0.0/10` CGNAT range Tailscale uses, and explicitly
     asks you to confirm — the UI labels this a guess, not a
     certainty.
4. Tests every address with `curl <url>/adv` and shows a per-address
   reachable/unreachable summary before continuing (an unreachable
   address isn't a hard stop — e.g. a Tailscale peer might legitimately
   be unreachable from the shell running Warden — but you're asked to
   confirm before proceeding).
5. Compares the `/adv` response body across reachable addresses to
   detect when two different addresses are actually the same physical
   Tang server (e.g. a LAN path and a Tailscale path to the same box).
   If such a pair mixes a Tailscale-flagged and a non-Tailscale
   address, surfaces the known SSS multi-pin timeout caveat before you
   commit to that combination: an unreachable pin can take several
   minutes to time out and fall through to the working one, per
   upstream Clevis behaviour.
6. If `clevis-tpm2` is installed, offers to include this machine's TPM2
   chip as an additional pin (a plain, unsealed `{}` config — no PCR
   selection UI yet), with the PCR-drift-after-firmware-update caveat.
7. Builds the final pin config:
   - Exactly one pin (a single Tang address, or TPM2 alone) → a plain
     `tang` or `tpm2` pin.
   - More than one pin → an `sss` pin. You're asked for a threshold,
     with "any 1 of N" vs "all N required" explained in plain terms.
     **Default suggestion is 1** ("any one pin"). If one of the pins is
     this host's own local Tang server, the UI explicitly flags that a
     threshold of 1 means the device can always unlock using just the
     local pin regardless of network reachability, and suggests
     raising the threshold to 2 if you actually want an external pin
     to be required.
8. Shows you the built config, then saves it (with the previous version
   backed up first) to `/etc/warden/tang-bindings.json`.

## What this does *not* do

The Tailscale `systemd-cryptsetup@<mapper>.service` ordering drop-in
described for Tailscale-flagged addresses is **not** created here — it
targets a specific device's mapper unit, and no device has been chosen
at this stage. Whether an address is Tailscale-flagged is saved in the
config; menus 4/5 create the drop-in automatically once they know
which device/mapper it applies to (see their docs).
