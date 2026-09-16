# Troubleshooting / FAQ

This page grows alongside the feature set — each phase adds the
failure modes relevant to what it ships. Currently covers Phase 0
(scaffolding) and Phase 1 (install, status dashboard).

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

## More FAQ entries land as each feature phase ships.

See the repository README for current phase status, and
[[Lessons Learned]] for the incidents behind Warden's safety design.
