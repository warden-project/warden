# shellcheck shell=bash
# lib/features/install.sh — menu 1: component installation
#
# clevis-initramfs (root-drive unlock) is deliberately not offered here.
# It requires its own guided wizard with extra warnings (never remove
# the original passphrase slot, confirm a recovery path exists first),
# which does not exist yet. Offering the bare package without that
# wizard would just invite exactly the kind of manual misuse this tool
# exists to prevent.

WARDEN_TANG_PKGS=(tang)
WARDEN_CLEVIS_CORE_PKGS=(clevis clevis-luks clevis-systemd)
WARDEN_CLEVIS_TPM2_PKG=clevis-tpm2
WARDEN_ZFS_PKG=zfsutils-linux
WARDEN_TAILSCALE_PKG=tailscale
: "${WARDEN_TAILSCALE_KEYRING:=/usr/share/keyrings/tailscale-archive-keyring.gpg}"
: "${WARDEN_TAILSCALE_APT_LIST:=/etc/apt/sources.list.d/tailscale.list}"
: "${WARDEN_OS_RELEASE_FILE:=/etc/os-release}"

# ubuntu_codename — this host's Ubuntu release codename (e.g. "noble"),
# read fresh from /etc/os-release each call rather than hardcoded, so
# this doesn't silently go stale if the supported release ever changes.
# Falls back to "noble" (24.04, this project's only supported release)
# if the file is missing or doesn't set VERSION_CODENAME.
ubuntu_codename() {
    local codename
    # shellcheck source=/dev/null
    codename="$(. "$WARDEN_OS_RELEASE_FILE" 2>/dev/null; echo "${VERSION_CODENAME:-}")"
    printf '%s' "${codename:-noble}"
}

# is_tailscale_connected — true if Tailscale is installed AND actually
# logged in/connected right now (BackendState "Running"), not just
# installed. Used to decide whether the post-install message needs to
# remind about the still-required 'tailscale up' step -- checking
# rather than assuming, so an already-joined host doesn't get an
# unnecessary/wrong reminder.
is_tailscale_connected() {
    command -v tailscale >/dev/null 2>&1 || return 1
    tailscale status --json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if data.get("BackendState") == "Running" else 1)
'
}

# is_tailscale_repo_configured — true if Tailscale's own apt source
# list is already present.
is_tailscale_repo_configured() {
    [[ -f "$WARDEN_TAILSCALE_APT_LIST" ]] && grep -q 'pkgs\.tailscale\.com/stable/ubuntu' "$WARDEN_TAILSCALE_APT_LIST" 2>/dev/null
}

# ensure_tailscale_repo_configured — idempotent: adds Tailscale's own
# apt repository and signing key, since Tailscale isn't in Ubuntu's
# default archives. Fetches a GPG keyring and a plain-text apt source
# list from Tailscale's own package server -- the same files, and same
# URLs, their own documented manual (non-interactive) install method
# uses -- never pipes a remote script into a shell.
ensure_tailscale_repo_configured() {
    if is_tailscale_repo_configured; then
        log_line "PKG: Tailscale apt repo already configured, skipping"
        return 0
    fi

    local codename
    codename="$(ubuntu_codename)"

    if [[ "${WARDEN_DRY_RUN}" == "1" ]]; then
        log_line "[DRY-RUN] would configure the Tailscale apt repository for ${codename}"
        printf '[DRY-RUN] would configure the Tailscale apt repository for %s\n' "$codename" >&2
        return 0
    fi

    run_cmd "fetch Tailscale's apt signing key" -- curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" -o "$WARDEN_TAILSCALE_KEYRING" || return 1
    [[ -f "$WARDEN_TAILSCALE_APT_LIST" ]] && backup_file "$WARDEN_TAILSCALE_APT_LIST" >/dev/null
    run_cmd "fetch Tailscale's apt source list" -- curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.tailscale-keyring.list" -o "$WARDEN_TAILSCALE_APT_LIST" || return 1
    run_cmd "refresh apt package lists" -- apt-get update
}

readonly WARDEN_INSTALL_REMINDER="Tang -- the server component. Runs on a machine and answers key-exchange requests. It doesn't keep a list of clients; anything that can reach it can request an exchange, so it's a network-trust model, not an authentication one.

Clevis -- the client component. Installed on each machine that has an encrypted drive. Binds a LUKS volume to one or more Tang servers (or a TPM2 chip), and unlocks it automatically at boot as long as it can complete that exchange."

# describe_install_status — current install state of every package
# this menu manages, one line per package.
describe_install_status() {
    local pkg
    for pkg in tang clevis clevis-luks clevis-systemd clevis-tpm2 zfsutils-linux tailscale; do
        if is_pkg_installed "$pkg"; then
            printf '  %s: installed\n' "$pkg"
        else
            printf '  %s: not installed\n' "$pkg"
        fi
    done
}

# install_selected <choice> <install_tpm2:0|1> <install_zfs:0|1> <install_tailscale:0|1>
# choice is one of: tang, clevis, both
install_selected() {
    local choice="$1" install_tpm2="${2:-0}" install_zfs="${3:-0}" install_tailscale="${4:-0}"

    ensure_universe_enabled

    if [[ "$choice" == "tang" || "$choice" == "both" ]]; then
        for pkg in "${WARDEN_TANG_PKGS[@]}"; do
            ensure_pkg_installed "$pkg"
        done
    fi

    if [[ "$choice" == "clevis" || "$choice" == "both" ]]; then
        for pkg in "${WARDEN_CLEVIS_CORE_PKGS[@]}"; do
            ensure_pkg_installed "$pkg"
        done
        if [[ "$install_tpm2" == "1" ]]; then
            ensure_pkg_installed "$WARDEN_CLEVIS_TPM2_PKG"
        fi
        if [[ "$install_zfs" == "1" ]]; then
            ensure_pkg_installed "$WARDEN_ZFS_PKG"
        fi
    fi

    # Not gated on choice, unlike tpm2/zfs above: Tailscale is equally
    # relevant to a Tang server host (so tangd can be reached safely
    # over the tailnet instead of the open network) and a Clevis
    # client host (so it can reach a remote Tang server the same way).
    if [[ "$install_tailscale" == "1" ]]; then
        ensure_tailscale_repo_configured
        ensure_pkg_installed "$WARDEN_TAILSCALE_PKG"
    fi
}

feature_install_menu() {
    warden_msg "Current install status" "$(describe_install_status)"
    warden_msg "Tang / Clevis -- what they do" "$WARDEN_INSTALL_REMINDER"

    local choice
    choice="$(warden_menu "Install components" "Which component(s) do you want to install?" \
        tang "Tang only (server)" \
        clevis "Clevis only (client)" \
        both "Both")" || return 0

    local install_tpm2=0 install_zfs=0
    if [[ "$choice" == "clevis" || "$choice" == "both" ]]; then
        if warden_yesno "Optional: clevis-tpm2" "Install clevis-tpm2 as well?\n\nAdds TPM2 pin support: binds a LUKS volume to this specific machine's TPM chip instead of (or alongside) a Tang server. Note: PCR-sealed bindings can break after firmware/kernel updates and need a re-bind."; then
            install_tpm2=1
        fi
        if warden_yesno "Optional: zfsutils-linux" "Install zfsutils-linux as well?\n\nLets menus 4/5 create or enrol a device as a single-disk ZFS pool instead of a plain filesystem, auto-importing/mounting it after unlock (no /etc/fstab entry -- ZFS doesn't use one)."; then
            install_zfs=1
        fi
    fi

    local install_tailscale=0
    if warden_yesno "Optional: Tailscale" "Install Tailscale as well?\n\nLets this host reach (or be reached by) a Tang server over a private tailnet instead of the open network -- relevant whether this host runs Tang, Clevis, or both.\n\nThis only installs the package (adding Tailscale's own apt repository, since it isn't in Ubuntu's default archives). Joining a tailnet ('tailscale up') is a separate, credential-specific step left to you."; then
        install_tailscale=1
    fi

    warden_msg "clevis-initramfs (root-drive unlock)" "Not offered yet: root-drive unlock needs its own guided wizard with extra safeguards, which hasn't been built. If you need this now, it's a manual, guide-only procedure -- see the wiki."

    if warden_yesno "Preview first?" "Show what would be installed without actually installing (dry-run)?"; then
        local saved_dry_run="${WARDEN_DRY_RUN}"
        WARDEN_DRY_RUN=1
        install_selected "$choice" "$install_tpm2" "$install_zfs" "$install_tailscale"
        WARDEN_DRY_RUN="$saved_dry_run"
        if ! warden_yesno "Proceed?" "Proceed with the real installation now?"; then
            return 0
        fi
    fi

    install_selected "$choice" "$install_tpm2" "$install_zfs" "$install_tailscale"

    local complete_msg="Requested package(s) are installed (or were already present)."
    if [[ "$install_tailscale" == "1" ]] && ! is_tailscale_connected; then
        complete_msg+="\n\nTailscale is installed but not yet connected to a tailnet. Run 'sudo tailscale up' to log in before relying on any Tailscale-routed Tang address."
    fi
    warden_msg "Install complete" "$complete_msg"
}
