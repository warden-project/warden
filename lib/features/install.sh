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

readonly WARDEN_INSTALL_REMINDER="Tang -- the server component. Runs on a machine and answers key-exchange requests. It doesn't keep a list of clients; anything that can reach it can request an exchange, so it's a network-trust model, not an authentication one.

Clevis -- the client component. Installed on each machine that has an encrypted drive. Binds a LUKS volume to one or more Tang servers (or a TPM2 chip), and unlocks it automatically at boot as long as it can complete that exchange."

# install_selected <choice> <install_tpm2:0|1>
# choice is one of: tang, clevis, both
install_selected() {
    local choice="$1" install_tpm2="${2:-0}"

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
    fi
}

feature_install_menu() {
    warden_msg "Tang / Clevis -- what they do" "$WARDEN_INSTALL_REMINDER"

    local choice
    choice="$(warden_menu "Install components" "Which component(s) do you want to install?" \
        tang "Tang only (server)" \
        clevis "Clevis only (client)" \
        both "Both")" || return 0

    local install_tpm2=0
    if [[ "$choice" == "clevis" || "$choice" == "both" ]]; then
        if warden_yesno "Optional: clevis-tpm2" "Install clevis-tpm2 as well?\n\nAdds TPM2 pin support: binds a LUKS volume to this specific machine's TPM chip instead of (or alongside) a Tang server. Note: PCR-sealed bindings can break after firmware/kernel updates and need a re-bind."; then
            install_tpm2=1
        fi
    fi

    warden_msg "clevis-initramfs (root-drive unlock)" "Not offered yet: root-drive unlock needs its own guided wizard with extra safeguards, which hasn't been built. If you need this now, it's a manual, guide-only procedure -- see the wiki."

    if warden_yesno "Preview first?" "Show what would be installed without actually installing (dry-run)?"; then
        local saved_dry_run="${WARDEN_DRY_RUN}"
        WARDEN_DRY_RUN=1
        install_selected "$choice" "$install_tpm2"
        WARDEN_DRY_RUN="$saved_dry_run"
        if ! warden_yesno "Proceed?" "Proceed with the real installation now?"; then
            return 0
        fi
    fi

    install_selected "$choice" "$install_tpm2"
    warden_msg "Install complete" "Requested package(s) are installed (or were already present)."
}
