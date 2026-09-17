# shellcheck shell=bash
# lib/features/uninstall.sh — menu 12: uninstall / revert
#
# Granular, not all-or-nothing. NEVER touches actual LUKS-encrypted
# data -- that's exclusively the Danger Zone's job (menu 11,
# lib/features/danger_erase.sh). This file must never source, call, or
# otherwise reach anything in danger_erase.sh: the two menus are
# reachable only from bin/warden's separate, flat dispatch on menu
# choice, with zero shared call path between them. If you're adding a
# new action here, it should unbind/disable/remove Warden-added
# config, never erase key material.

# devices_with_clevis_bindings — "<devpath> <uuid> <mapper>" for every
# managed device that currently has at least one Clevis binding.
devices_with_clevis_bindings() {
    local dev uuid mapper
    while read -r dev uuid mapper; do
        [[ -n "$dev" ]] || continue
        [[ -n "$(clevis_pins_for_device "$dev")" ]] || continue
        printf '%s %s %s\n' "$dev" "$uuid" "$mapper"
    done < <(managed_luks_devices)
}

feature_uninstall_menu() {
    local action
    action="$(warden_menu "Uninstall / revert" "What do you want to revert? Each action is independent -- picking one does not affect the others." \
        lateboot "Disable the late-boot unlocker only (revert to manual unlock)" \
        unbind "Unbind Clevis from a device (revert to manual unlock for that device)" \
        dropins "Remove Warden-added systemd drop-ins (e.g. Tailscale ordering)" \
        packages "Uninstall Tang/Clevis packages")" || return 0

    case "$action" in
        lateboot) uninstall_action_disable_lateboot ;;
        unbind) uninstall_action_unbind_device ;;
        dropins) uninstall_action_remove_dropins ;;
        packages) uninstall_action_remove_packages ;;
    esac
}

uninstall_action_disable_lateboot() {
    if ! is_pkg_installed clevis-systemd; then
        warden_msg "Nothing to do" "clevis-systemd isn't installed, so the late-boot unlocker isn't set up."
        return 0
    fi

    if ! warden_yesno "Current status" "$(describe_lateboot_status)\n\nDisable and stop it now? This reverts to manual (passphrase) unlock at boot for every device -- existing Clevis bindings and packages are left alone."; then
        return 0
    fi

    ensure_systemd_unit_disabled "$WARDEN_ASKPASS_PATH_UNIT"
    ensure_systemd_unit_inactive "$WARDEN_ASKPASS_PATH_UNIT"

    warden_msg "Done" "$(describe_lateboot_status)"
}

uninstall_action_unbind_device() {
    local -a menu_items=()
    local dev uuid mapper
    while read -r dev uuid mapper; do
        [[ -n "$dev" ]] || continue
        menu_items+=("$dev" "mapper: ${mapper}")
    done < <(devices_with_clevis_bindings)

    if [[ "${#menu_items[@]}" -eq 0 ]]; then
        warden_msg "Nothing to do" "No managed device currently has a Clevis binding."
        return 0
    fi

    dev="$(warden_menu "Select a device" "Devices with Clevis bindings:" "${menu_items[@]}")" || return 0

    warden_msg "Current bindings on ${dev}" "$(describe_slots "$dev")"

    if ! warden_yesno "Point of no return for this device" "This removes EVERY Clevis binding from ${dev}, reverting it to manual (passphrase-only) unlock. It cannot auto-unlock at boot again until re-enrolled.\n\nDo you have this device's LUKS recovery passphrase in hand right now?"; then
        return 0
    fi

    local slot any_failed=0
    while IFS= read -r slot; do
        [[ -n "$slot" ]] || continue
        run_clevis_luks_unbind "$dev" "$slot" || any_failed=1
    done < <(slot_numbers "$dev")

    if [[ "$any_failed" == "1" ]]; then
        warden_msg "Some bindings could not be removed" "Check the session log at ${WARDEN_LOG_FILE}.\n\nRemaining bindings on ${dev}:\n\n$(describe_slots "$dev")"
    else
        warden_msg "Done" "All Clevis bindings removed from ${dev}. It now requires the LUKS passphrase to unlock.\n\nRemaining bindings:\n\n$(describe_slots "$dev")"
    fi
}

uninstall_action_remove_dropins() {
    local -a menu_items=()
    local f
    while read -r f; do
        [[ -n "$f" ]] || continue
        menu_items+=("$f" "")
    done < <(tailscale_ordering_dropins)

    if [[ "${#menu_items[@]}" -eq 0 ]]; then
        warden_msg "Nothing to do" "No Warden-added Tailscale ordering drop-ins were found."
        return 0
    fi

    local file
    file="$(warden_menu "Select a drop-in to remove" "Warden-added systemd drop-ins:" "${menu_items[@]}")" || return 0

    if ! warden_yesno "Confirm" "Remove ${file}?\n\nThis only removes the ordering drop-in -- it does not unbind Clevis or change crypttab/fstab. The device will still auto-unlock, just without waiting for Tailscale specifically."; then
        return 0
    fi

    backup_file "$file" >/dev/null
    run_cmd "remove drop-in ${file}" -- rm -f "$file"
    local dir
    dir="$(dirname "$file")"
    rmdir --ignore-fail-on-non-empty "$dir" 2>/dev/null || true
    run_cmd "reload systemd units" -- systemctl daemon-reload

    warden_msg "Done" "${file} removed (backed up first)."
}

uninstall_action_remove_packages() {
    warden_msg "Current install status" "$(describe_install_status)"

    local choice
    choice="$(warden_menu "Uninstall packages" "Which package(s) do you want to remove?" \
        tang "Tang only" \
        clevis "Clevis (clevis clevis-luks clevis-systemd)" \
        clevis-tpm2 "clevis-tpm2 only" \
        all "Everything Warden might have installed")" || return 0

    if ! warden_yesno "Confirm" "This uninstalls packages only -- it does not touch crypttab/fstab, existing Clevis bindings, or LUKS data. Proceed?"; then
        return 0
    fi

    case "$choice" in
        tang) ensure_pkg_removed tang ;;
        clevis)
            ensure_pkg_removed clevis-systemd
            ensure_pkg_removed clevis-luks
            ensure_pkg_removed clevis
            ;;
        clevis-tpm2) ensure_pkg_removed clevis-tpm2 ;;
        all)
            ensure_pkg_removed clevis-systemd
            ensure_pkg_removed clevis-luks
            ensure_pkg_removed clevis-tpm2
            ensure_pkg_removed clevis
            ensure_pkg_removed tang
            ;;
    esac

    warden_msg "Done" "$(describe_install_status)"
}