# shellcheck shell=bash
# lib/features/uninstall.sh — menu 13: uninstall / revert
#
# Granular, not all-or-nothing. NEVER touches actual LUKS-encrypted
# data -- that's exclusively the Danger Zone's job (menu 14,
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
        forget "Remove crypttab/fstab entries for a device Warden no longer manages" \
        dropins "Remove Warden-added systemd drop-ins (e.g. Tailscale ordering)" \
        packages "Uninstall Tang/Clevis packages")" || return 0

    case "$action" in
        lateboot) uninstall_action_disable_lateboot ;;
        unbind) uninstall_action_unbind_device ;;
        forget) uninstall_action_forget_device ;;
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

# uninstall_action_forget_device — remove a device's crypttab (and
# fstab, if present) entry entirely, plus its ZFS boot-time import unit
# if it has one.
#
# Found missing during real-hardware testing of the Danger Zone erase
# (menu 14): after an erase, every keyslot is gone, so the device can
# never unlock again -- but its crypttab entry has no "nofail" option
# (see build_crypttab_line in lib/features/luks_enroll.sh), so leaving
# it in place risks hanging the next boot waiting to unlock a device
# that has no possible correct answer anymore. "unbind" above doesn't
# help here: it reverts to manual passphrase unlock, which assumes a
# working passphrase keyslot still exists. This only touches
# crypttab/fstab and the ZFS import unit -- never the LUKS header,
# keyslots, or Clevis bindings, and never zpool/zfs destroy (export
# only, so the pool's data is untouched and could still be re-imported
# manually later if needed).
uninstall_action_forget_device() {
    local -a menu_items=()
    local dev uuid mapper
    while read -r dev uuid mapper; do
        [[ -n "$dev" ]] || continue
        menu_items+=("$dev" "mapper: ${mapper}")
    done < <(managed_luks_devices)

    if [[ "${#menu_items[@]}" -eq 0 ]]; then
        warden_msg "Nothing to do" "No managed device (with a crypttab entry) was found."
        return 0
    fi

    dev="$(warden_menu "Select a device" "Managed devices:" "${menu_items[@]}")" || return 0
    uuid="$(uuid_for_device "$dev")"
    mapper="$(crypttab_mapper_for_uuid "$uuid")"

    local bindings has_zfs_unit=0
    bindings="$(clevis_pins_for_device "$dev")"
    is_systemd_unit_enabled "warden-zfs-import@${mapper}.service" 2>/dev/null && has_zfs_unit=1

    local msg="Mapper: ${mapper}\nUUID: ${uuid}\nClevis bindings: ${bindings:-none}\n\nThis removes ${mapper}'s entry from ${WARDEN_CRYPTTAB} (and ${WARDEN_FSTAB}, if present), so systemd stops trying to unlock/mount it at boot."
    if [[ "$has_zfs_unit" == "1" ]]; then
        msg+="\n\nThis device also has a boot-time ZFS import unit (warden-zfs-import@${mapper}.service) enabled. It will be disabled, and the zpool exported if currently imported -- the pool and its data are left intact and could still be re-imported manually later."
    fi
    msg+="\n\nUse this once a device is done being managed by Warden -- most importantly after a Danger Zone erase (menu 14), since a device with no key slots left can never unlock again, and an entry left behind for it can hang the next boot.\n\nThis does NOT touch the LUKS header, keyslots, or any Clevis binding on the device itself.\n\nProceed?"

    if ! warden_yesno "Remove crypttab/fstab entries for ${dev}" "$msg"; then
        return 0
    fi

    remove_lines_matching "$WARDEN_CRYPTTAB" "^${mapper}[[:space:]]"
    remove_lines_matching "$WARDEN_FSTAB" "/dev/mapper/${mapper}([[:space:]]|\$)"

    local done_msg="${mapper}'s crypttab/fstab entries have been removed (backed up first)."
    if [[ "$has_zfs_unit" == "1" ]]; then
        if zpool list "$mapper" >/dev/null 2>&1; then
            run_cmd "export zpool ${mapper}" -- zpool export "$mapper" >/dev/null
        fi
        disable_zfs_import_unit "$mapper"
        done_msg+="\n\nThe ${mapper} ZFS import unit was disabled, and the pool exported if it was imported."
    fi

    warden_msg "Done" "$done_msg"
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