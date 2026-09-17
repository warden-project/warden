# Troubleshooting / FAQ

This page grows alongside the feature set — each phase adds the
failure modes relevant to what it ships. Currently covers Phase 0
(scaffolding) and Phase 4 (install, Tang server config, Tang
bindings/SSS/Tailscale, the LUKS wizards, the late-boot unlocker,
status dashboard, and Maintenance: binding rotation, header backup,
Tang key rotation).

## "warden: must be run as root"

Warden requires root up front rather than elevating per command, so
that privilege is a single, visible, consciously-granted precondition
rather than a series of `sudo` prompts scattered through a wizard. Run
it with `sudo bin/warden`.

## Where's the session log?

`/var/log/warden/warden-<timestamp>-<pid>.log`, one per run. It records
every command considered (including ones skipped in dry-run mode), its
output, and any file diffs from crypttab/fstab edits.

## Where are file backups kept?

`/var/backups/warden/`, timestamped per file per edit. Nothing is ever
edited in place without one being taken first.

## The status dashboard says a Tang server is "unreachable" but I can `curl` it fine manually

Check you're testing the exact same URL Warden is: the dashboard tests
the URL(s) actually embedded in existing Clevis bindings, read from
`clevis luks list`, not a separately-configured list (menu 3, which
builds that list, doesn't exist yet). If a binding was made with a
Tailscale address and you're testing from a machine that isn't on the
tailnet, that's the expected result, not a bug.

## The status dashboard shows "Clevis bindings: (clevis not installed)"

That's the literal state — no packages are auto-inferred as installed.
This exact class of "assumed it was there" gap is why `clevis-systemd`
being missed was a real incident; see [[Lessons Learned]].

## The binding wizard says an address "might be Tailscale" and asks me to confirm

That happens when the `tailscale` CLI isn't available on this host to
check automatically, and the address you entered falls in
`100.64.0.0/10` — the CGNAT range Tailscale uses. It's flagged as a
guess deliberately: that range isn't exclusively Tailscale's, so
Warden asks rather than assuming.

## Why does menu 3 default the SSS threshold to "any 1 pin" instead of "all required"?

Availability usually matters more than strictness for boot-time
unlock — you generally want the drive to unlock if *any* trusted path
works, not to fail because one of several redundant paths is down. The
one exception the wizard calls out explicitly is when one of the pins
is this host's own local Tang server: see [[NBDE Explained]] for why
that specific combination is worth reconsidering.

## Where does menu 3 save its trust configuration?

`/etc/warden/tang-bindings.json`, with the previous version backed up
before each overwrite, same as every other file Warden edits.

## Why do I have to type "FORMAT `<8 characters>`" instead of just confirming yes/no?

The 8 characters are read directly off the device identifier shown on
screen at that exact moment (a UUID fragment, or the device path for a
brand-new blank device). A fixed word or a y/n answer can be given from
habit without re-checking the target; this can only be typed correctly
by actually reading what's currently on screen. See [[Lessons
Learned]] for the near-miss this specifically guards against.

## My device didn't show up in the LUKS enrolment wizard's list

Two possible reasons: it's already in `/etc/crypttab` (check the status
dashboard, menu 7), or it's been excluded because it is or backs this
system's root filesystem, `/boot`, or `/boot/efi`. The second case is
deliberate — root-drive unlock is a separate, not-yet-built feature by
design, not an oversight.

## The bind succeeded but the test-unlock failed — is the device broken?

No. The Clevis binding was added to the LUKS header, but the wizard's
own test-unlock (into a throwaway mapper name, cleaned up immediately)
didn't succeed — usually a Tang reachability problem, not device
corruption. Check the Tang server status on the dashboard (menu 7) and
the session log before rebooting anything relying on this binding.

## Why doesn't CI run the test suite, only shellcheck?

The only Forgejo runner registered on this instance is the shared dev
host itself (labeled `vm-host`), running as a non-root
`forgejo-runner` user — not an ephemeral or containerized runner.
Running the bats suite there would mean every push installs
`tang`/`clevis`/`clevis-luks` and runs real `cryptsetup`/`losetup`
directly against that shared machine, which is a different risk
profile than the disposable-sandbox testing this project is built
around. CI is scoped to `shellcheck` only for that reason; run
`bats tests/bats/` as root locally, or on a dedicated disposable test
VM, to exercise the root-gated tests for real.

## Menu 8's "rotate" option didn't remove the old binding

That's by design if the new binding's test-unlock failed. Rotation
only offers to remove the old slot(s) once the new one has proven it
actually works — if verification fails, the old binding is left
completely alone so the device isn't left worse off than before you
started. Check Tang reachability and the session log, fix the
underlying issue, and try again.

## Menu 10 says it can't find the Tang key rotation helper

Warden looks for upstream Tang's bundled `tangd-rotate-keys` script at
a couple of conventional paths (`/usr/libexec/`, `/usr/lib/tangd/`)
and falls back to a `PATH` lookup — this hasn't been verified against
a real Ubuntu `tang` package install yet. If your install has it
somewhere else, set `WARDEN_TANGD_ROTATE_KEYS_CANDIDATES` (space
separated paths) rather than Warden guessing at reimplementing key
rotation by hand.

## More FAQ entries land as each feature phase ships.

See the repository README for current phase status, and
[[Lessons Learned]] for the incidents behind Warden's safety design.
