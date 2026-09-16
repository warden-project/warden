# Troubleshooting / FAQ

This page grows alongside the feature set — each phase adds the
failure modes relevant to what it ships. Currently covers Phase 0
(scaffolding) only.

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

## More FAQ entries land as each feature phase ships.

See the repository README for current phase status, and
[[Lessons Learned]] for the incidents behind Warden's safety design.
