# shellcheck shell=bash
# lib/features/lateboot.sh — menu 6: enable/verify the late-boot unlocker
#
# clevis-systemd being silently missing (clevis/clevis-luks installed,
# clevis-systemd not) is a confirmed past incident: everything about a
# binding can be correct and boot will still hang waiting for a
# passphrase, because nothing was listening to answer it automatically.
# This menu item exists specifically to make that check explicit and
# to report real status, not assume success.
#
# Depends on unit_state(), defined in lib/features/status.sh -- sourced
# earlier in bin/warden.

: "${WARDEN_ASKPASS_PATH_UNIT:=clevis-luks-askpass.path}"

# describe_lateboot_status — current enabled/active state of the
# late-boot unlocker unit, shown before offering to change anything.
describe_lateboot_status() {
    printf 'clevis-systemd: installed\n'
    printf '%s enabled: %s\n' "$WARDEN_ASKPASS_PATH_UNIT" "$(is_systemd_unit_enabled "$WARDEN_ASKPASS_PATH_UNIT" 2>/dev/null && echo yes || echo no)"
    printf '%s state: %s\n' "$WARDEN_ASKPASS_PATH_UNIT" "$(unit_state "$WARDEN_ASKPASS_PATH_UNIT")"
}

feature_lateboot_menu() {
    if ! is_pkg_installed clevis-systemd; then
        warden_msg "clevis-systemd not installed" "clevis-systemd isn't installed. Without it, nothing listens for the boot-time password request, so Clevis bindings will not unlock automatically at boot even if everything else is configured correctly.\n\nInstall it from menu 1 first."
        return 0
    fi

    if ! warden_yesno "Current status" "$(describe_lateboot_status)\n\nEnsure it's enabled and re-check status now?"; then
        return 0
    fi

    ensure_systemd_unit_enabled "$WARDEN_ASKPASS_PATH_UNIT"

    local state
    state="$(unit_state "$WARDEN_ASKPASS_PATH_UNIT")"
    if [[ "$state" == "active" ]]; then
        warden_msg "Late-boot unlocker enabled" "${WARDEN_ASKPASS_PATH_UNIT} is enabled and active.\n\nThis does not guarantee any specific device will unlock at boot -- that also depends on the device having a working Clevis binding (menus 4/5) and its Tang server(s) being reachable at boot time."
    else
        warden_msg "Enabled, but not currently active" "${WARDEN_ASKPASS_PATH_UNIT} is enabled, but its current state is '${state}', not 'active'.\n\nCheck 'systemctl status ${WARDEN_ASKPASS_PATH_UNIT}' and the session log at ${WARDEN_LOG_FILE}."
    fi
}
