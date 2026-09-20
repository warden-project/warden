# Menu 14 — Health check

A single pass/fail pass across everything else in this tool already
configured, so checking whether it's all still healthy doesn't mean
visiting several other menus by hand. Read-only, like the status
dashboard (menu 7) — this never changes anything.

Checks, each shown as `PASS`/`FAIL`/`WARN` (or a plain note when
there's nothing of that kind configured to check):

- **Tang reachability** — every unique Tang URL referenced by any
  current binding, secondary drive or root, not just the ones a
  currently-open device happens to show elsewhere.
- **TPM2** — only checked at all if some binding actually uses a tpm2
  pin (directly, or nested inside an SSS threshold config). Confirms
  the TPM2 device node is present and `clevis-tpm2` is installed.
- **ZFS import units** — for every managed secondary device backed by
  a ZFS pool, confirms its boot-time import unit is both enabled and
  active. Root-drive unlock never supports ZFS, so this only ever
  looks at secondary devices.
- **Late-boot unlocker** — only checked if `clevis-systemd` is
  installed. Confirms `clevis-luks-askpass.path` is active.
- **Root-drive unlock drift** — only checked if root-drive unlock is
  enabled. A `WARN`, not a `FAIL`: drift means the recovery kit is
  stale, not that any binding is at risk (see menu 13's Status for
  why) — still surfaced here since it needs attention (run Snapshot),
  just phrased as a warning rather than an error.

Every individual check reuses a function menu 7 or menu 13 already has
and already tests — this menu is composition, not new logic.

## Non-interactive use: `warden check`

The exact same report is available without whiptail:

```sh
sudo warden check
```

Prints the report to stdout and exits `0` if everything passed, `1` if
anything needs attention (a real failure, or root-unlock drift) — the
same text and exit-code contract as the interactive menu, so there's
only one implementation to keep correct. Suitable for a cron job or a
monitoring check: capture the output, act on the exit code.
