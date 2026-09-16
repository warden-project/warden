# Build prompt for Claude Code: "Warden" — a Tang/Clevis (NBDE) management TUI

Copy everything below the line into Claude Code as your starting prompt.

---

## Project summary

Build a TUI (menu-driven terminal) tool called **Warden** for managing Network-Bound Disk Encryption (NBDE) on Ubuntu Server machines — installing and configuring Tang (server) and Clevis (client), binding LUKS-encrypted drives to Tang servers (including via Tailscale), and handling the ongoing lifecycle: key rotation, backups, uninstall, and secure disposal.

This tool targets **Ubuntu Server hosts only**. It does not manage the Tang server that runs as a Docker container on a separate Unraid NAS — that's configured through Unraid's own Docker UI and is out of scope. Where an Ubuntu host also runs Tang itself (as a native systemd service, not Docker), that IS in scope.

The person operating this tool is comfortable at a shell but wants guided, safe, repeatable workflows instead of hand-typing `cryptsetup`/`clevis` commands from a wiki page every time — because that's exactly what's been happening, including one near-miss where an EFI boot partition was almost run through `cryptsetup luksFormat` by mistake, and one confirmed instance of a required package (`clevis-systemd`) being missed. Design against exactly these kinds of mistakes.

## Non-negotiable safety and idempotency requirements

- **Every operation must check current state before acting.** Running Warden twice in a row, or interrupting it halfway (Ctrl-C, power loss, reboot) and running it again, must never leave the system in a broken or inconsistent state, and must never redo work that's already done or duplicate config entries.
- **Never assume `/dev/sdX` naming is stable.** Internally, always resolve and store devices by UUID (or LUKS UUID). Device letters may be shown in menus for human readability but must be re-resolved to UUID before use in any command or config file.
- **Before any destructive disk operation** (`cryptsetup luksFormat`, `luksErase`, anything that writes to a device), Warden must:
  - Display the full current `lsblk -f`-equivalent output so the person can visually confirm the target
  - Clearly flag if the selected device is, or contains, the current root filesystem, `/boot`, or `/boot/efi` — refuse by default, and require a distinct, explicit override step to proceed (e.g. typing the device's UUID back, not just "y")
  - Require a typed confirmation phrase (not a single-key y/n) before proceeding, showing exactly what will happen
- **Back up before modifying.** Never edit `/etc/crypttab` or `/etc/fstab` in place without first copying the existing file to a timestamped backup location. Prefer targeted, minimal edits (append/patch specific lines) over regenerating the whole file, so unrelated existing entries are never touched or reordered.
- **Offer a dry-run/preview mode** for every wizard: show the exact commands and file changes that would be made, without executing, before committing.
- **Log everything.** Every action Warden takes (commands run, files changed, before/after diffs) goes to a timestamped log file, so a session can be reconstructed and audited afterwards.
- **Idempotent package installs**: check whether a package is already installed before attempting to install it; check whether a systemd unit is already enabled before enabling it; check whether a crypttab/fstab line already exists before adding it.

## Menu structure

Top-level menu, split into **Day 0** and **Day 1**, plus **Maintenance**, a clearly separated **Danger Zone**, and **Uninstall / Revert**:

```
Warden — NBDE Management
─────────────────────────
 Day 0 — Initial setup
   1) Install components (Tang / Clevis / both)
   2) Configure Tang server (ports, systemd socket)
   3) Configure Tang server(s) to trust (bindings), including Tailscale detection & SSS

 Day 1 — Ongoing configuration
   4) LUKS setup wizard (new / non-encrypted device)
   5) LUKS enrolment wizard (existing LUKS device → crypttab/fstab/Clevis)
   6) Enable/verify late-boot unlocker
   7) Status dashboard

 Maintenance
   8) Add / remove / rotate a binding
   9) Backup LUKS header(s)
  10) Rotate Tang server keys (if this host runs Tang)

 ⚠ DANGER ZONE
  11) Erase LUKS header (cryptographic erase / secure disposal)

 12) Uninstall / revert
 13) Exit
```

## Feature detail

### 1. Component installation, with reminders

Offer: Tang only / Clevis only / Both. Before the choice, show a short, plain-language reminder (bake this into the menu's help text, don't make Claude Code invent different wording):

> **Tang** — the server component. Runs on a machine and answers key-exchange requests. It doesn't keep a list of clients; anything that can reach it can request an exchange, so it's a network-trust model, not an authentication one.
>
> **Clevis** — the client component. Installed on each machine that has an encrypted drive. Binds a LUKS volume to one or more Tang servers (or a TPM2 chip), and unlocks it automatically at boot as long as it can complete that exchange.

Package installs, idempotent (check `dpkg -l` first):
- Tang: `tang`
- Clevis core: `clevis clevis-luks clevis-systemd`
- Optional, offered separately with a one-line explanation of what each adds: `clevis-initramfs` (root-drive unlock — see the root-drive section below for required extra warnings), `clevis-tpm2` (TPM2 pin support)
- Confirm Ubuntu's `universe` archive is enabled before installing (`add-apt-repository universe` if not)

### 2. Tang server configuration

If Tang is selected for install:
- Ask for a port (default suggestion, but let the person override) and write it via a `systemctl edit tangd.socket` drop-in (`ListenStream=` cleared then reset), not by hand-editing the shipped unit
- Enable and start `tangd.socket`
- Open the firewall port if `ufw` is active (detect first; don't assume it's installed/active)
- Verify with a local `curl http://localhost:<port>/adv` and report success/failure clearly
- Remind the person that `/var/db/tang/` needs backing up outside this tool (Warden can point this out but backing up to *another* location is the person's call, not something to automate blindly)

### 3. Tang servers to bind to (including localhost, Tailscale detection, and SSS)

A wizard that:
- Lets the person add one or more Tang server addresses (host:port), including explicitly offering `127.0.0.1`/`localhost` as an option when Tang is also installed locally on this same host
- **Tailscale detection**: for each address entered, determine if it's a Tailscale address:
  - Primary method: if the `tailscale` CLI is present, run `tailscale status --json` and check whether the host matches a known tailnet peer
  - Fallback heuristic (clearly labelled as a guess, not a certainty, if the CLI isn't available): flag addresses in the `100.64.0.0/10` CGNAT range that Tailscale uses, and ask the person to confirm
  - If a Tailscale address is confirmed, offer to add a systemd drop-in on the relevant `systemd-cryptsetup@<name>.service` unit:
    ```ini
    [Unit]
    After=tailscale-online.target
    Wants=tailscale-online.target
    ```
    Explain in the UI *why*: `network-online.target` only means basic networking is up, not that Tailscale has finished connecting, and ordering against `tailscaled.service` alone isn't reliable.
- **SSS configuration**: if more than one Tang address is given (or a mix of Tang + TPM2), build the correct `sss` pin config with a chosen threshold `t`. Explain the threshold choice in plain terms ("any 1 of 2" vs "both required"). If the person is combining a LAN address and a Tailscale address for the *same* physical Tang server, surface the known timeout caveat clearly before they commit: an unreachable pin can take several minutes to time out and fall through to the working one, per the documented Clevis behaviour — this isn't a bug in Warden, it's upstream behaviour worth knowing about in advance.
- Test each configured address with `curl <url>/adv` before allowing the binding to proceed, and show the result per-address (reachable/unreachable) rather than failing silently.

### 4. LUKS setup wizard (device isn't encrypted yet)

For a device the person selects that isn't already LUKS:
- Show `lsblk -f` and require explicit confirmation of the target (see safety requirements above — including the root/boot/EFI guard)
- Warn clearly that formatting destroys existing data; require confirmation
- `cryptsetup luksFormat`, prompting for (or optionally generating and clearly displaying, with a "you must save this now" warning) a strong recovery passphrase
- Open it, create a filesystem (ask which — default `ext4`), close it again
- Hand off into the enrolment wizard (step 5) using the UUID just created, so the person doesn't have to re-enter anything

### 5. LUKS enrolment wizard (existing LUKS device)

- Detect all `crypto_LUKS` devices on the system (via `lsblk`) and show which are already in `/etc/crypttab` vs not, so the person isn't left guessing (this exact "wait, is this already managed?" confusion came up in practice)
- For an unmanaged one: ask for (or suggest, based on existing mapper naming conventions already on the system) a mapper name, add the `crypttab` line (`UUID=... none luks,_netdev`) and the matching `fstab` line (`/dev/mapper/<name> <mountpoint> <fstype> defaults,nofail 0 2`), both via minimal/targeted edits with a backup taken first
- Run `clevis luks bind` with whichever pin config was built in step 3 (single tang / sss / tpm2)
- Offer an immediate test (`clevis luks unlock -d ... -n warden-test`, then clean up the test mapping) before relying on a reboot to find out if it worked

### 6. Late-boot unlocker

- Verify `clevis-systemd` is actually installed (this exact gap has already caused a failure — don't just assume it's bundled)
- `systemctl enable clevis-luks-askpass.path` (idempotent — check enabled state first)
- Report current status (`systemctl status clevis-luks-askpass.path`) so the person can see it's live, not just "assume it worked"

### 7. Status dashboard

A read-only view showing, for each managed device:
- Mapper name, UUID, crypttab/fstab status
- Current Clevis binding(s) (`clevis luks list`) per device
- Live reachability check for every configured Tang server (`curl .../adv`, with latency)
- `tangd.socket` and `clevis-luks-askpass.path` unit status if applicable
- Any Tailscale-ordering drop-ins currently in place

### 8. Add / remove / rotate a binding

Implement the safe pattern established for changing any existing binding: **bind the new config first (into a fresh slot), verify it, only then unbind the old one** — never edit a binding in place. Offer this as a guided flow rather than requiring the person to remember slot numbers by hand; Warden should look up and display the slot itself.

### 9. Backup LUKS header(s)

- `cryptsetup luksHeaderBackup` to a clearly named, timestamped file in a dedicated backups directory
- Remind (in the UI, not just docs) that a header backup contains wrapped key material and is sensitive — store it somewhere the encrypted drive's own failure wouldn't also take out the backup

### 10. Rotate Tang server keys

Distinct from rotating a *client's* binding (that's covered by item 8) — this is for a host that runs Tang itself:
- Run the Tang key rotation helper, explain that old keys are retained (prefixed) so existing bindings keep working, and that clients should be re-bound over time and old keys cleaned up only once nothing depends on them
- Only offer this option if Tang is actually installed on this host

### 11. ⚠ Danger Zone — cryptographic erase

This is for secure disposal of a drive (e.g. a faulty drive that can't reliably be wiped a normal way) — **not** a routine maintenance action, and the UI should look and feel distinctly different from the rest of the tool (different colour/heading if the TUI library supports it, an explicit "DANGER ZONE" banner).

- Show the device, its current key slots/bindings, and explicitly ask whether a header backup exists anywhere (Warden can't know this for certain — ask the person to confirm, and remind them a backup would also need destroying for the erase to actually be final)
- Require a typed confirmation that repeats back the exact device UUID, not a generic yes/no
- Run `cryptsetup luksErase` (or `cryptsetup erase`)
- Explain, before and after, that this destroys all key slots and headers only — it does **not** overwrite the bulk data area, but without any key slot left, the encrypted data is permanently unrecoverable. This is the recognised "Cryptographic Erase" technique (NIST SP 800-88 Purge-level sanitisation) — appropriate for exactly the case of a drive that can't safely undergo a full wipe.

### 12. Uninstall / revert

Granular, not all-or-nothing:
- Disable the late-boot unlocker only (revert to manual unlock) — leave bindings and packages alone
- Unbind Clevis from a chosen device (require confirming the person has the recovery passphrase in hand first, since this is the point of no return for automatic unlocking on that device)
- Remove Warden-added systemd drop-ins (e.g. the Tailscale ordering override)
- Uninstall packages
- **Never** touch actual LUKS-encrypted data as part of "uninstall" — that's exclusively the Danger Zone's job, and the two must not be reachable from the same confirmation flow.

### Root-drive unlock (`clevis-initramfs`) — treat as high-risk, separate from the rest

Getting root-disk initramfs unlock wrong can leave a machine unable to boot at all, which is a materially worse failure mode than a secondary drive not auto-unlocking. Recommend to Claude Code:
- Either omit this from v1 entirely and document it as a manual, guide-only procedure, **or**
- Include it but gate it behind its own explicit menu path with extra warnings, always confirm a rescue/recovery path exists (e.g. "do you have bootable recovery media?") before proceeding, and never remove the original passphrase slot
- Whichever is chosen, this must never be reachable accidentally from the general LUKS enrolment wizard — it's a deliberately separate decision.

### TPM2 pin support

Offer `tpm2` as an available pin type alongside `tang` and `sss` in the binding wizards (step 3/5), for anyone who wants a drive tied to specific hardware rather than network reachability. Include the practical caveat in the UI: PCR-sealed bindings can break after firmware/kernel updates, requiring a re-bind.

## Tooling recommendation

Suggest Bash with `whiptail` or `dialog` for the menu system: minimal dependencies (near-guaranteed present on Ubuntu Server), and — given this tool edits disk encryption config — every action stays easy to read and audit line-by-line rather than hidden behind a larger framework. If Claude Code has a good reason to prefer Python (e.g. for testability or cleaner state handling), that's acceptable, but justify the choice rather than defaulting to it, and keep the same auditability bar: it should be easy for the person to read exactly what a given menu action will run before choosing to run it.

## Documentation and wiki

- A top-level `README.md`: purpose, quick start, architecture overview, safety model, prerequisites
- Usage docs walking through each menu path
- A Forgejo wiki, created and kept up to date alongside the code (not a one-off), including:
  - How NBDE actually works here (crypttab, fstab, the late-boot unlocker mechanism) — written for future-reference, not just for people who already know it
  - Troubleshooting / FAQ
  - A "lessons learned" page capturing the real gotchas that shaped this tool's safety design: the EFI-partition near-miss, the missing `clevis-systemd` package, the multi-pin SSS timeout behaviour, and the Tailscale ordering gap
- Treat documentation updates as part of any future change, not an afterthought — a change that isn't reflected in the docs/wiki isn't finished.

## Hosting

This needs to live on the Forgejo instance, in a new repository. Proposed name: **`nbde-warden`** (rename if you'd prefer). Target organisation: **`projects`**. Set up the repository with the wiki enabled from the start.
