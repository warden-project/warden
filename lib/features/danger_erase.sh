# shellcheck shell=bash
# lib/features/danger_erase.sh — menu 11: DANGER ZONE, cryptographic erase
#
# For secure disposal of a drive (e.g. one that can't reliably be wiped
# the normal way) -- NOT a routine maintenance action. This is the
# single highest-risk action in the whole tool: it is irreversible by
# design. Every screen from the explanation onward uses the Danger
# Zone's distinct visual treatment (danger_msg/danger_yesno/
# danger_textbox, and WARDEN_DANGER_BACKTITLE threaded through the
# shared confirmation gate) so it never looks like a routine screen.
#
# Uninstall/revert (menu 12) must never be able to reach this code path
# -- see lib/features/uninstall.sh, which only ever unbinds Clevis
# bindings, never erases a LUKS header.

readonly WARDEN_DANGER_ERASE_EXPLANATION="This performs a cryptographic erase: it destroys every LUKS key slot and the header itself, but does NOT overwrite the bulk data area.

Without any key slot left, the encrypted data is permanently unrecoverable -- this is the recognised NIST SP 800-88 Purge-level sanitisation technique, appropriate specifically for a drive that can't safely undergo a full data wipe.

This cannot be undone. There is no slot to fall back on afterward -- not a passphrase, not a keyfile, not a Clevis binding."

# describe_device_for_erase <dev> — Clevis bindings plus the raw
# cryptsetup keyslot inventory, so "current key slots/bindings" means
# literally everything, not a curated subset.
describe_device_for_erase() {
    local dev="$1"
    echo "Clevis bindings:"
    describe_slots "$dev" | sed 's/^/  /'
    echo
    echo "All key slots (cryptsetup):"
    cryptsetup luksDump "$dev" 2>/dev/null | awk '
        /^Keyslots:/ { flag=1; next }
        /^[A-Za-z]/ { flag=0 }
        flag { print }
    '
}

run_luks_erase() {
    local dev="$1"
    run_cmd "cryptographically erase ${dev}" -- cryptsetup luksErase --batch-mode "$dev"
}

feature_danger_erase_menu() {
    local -a menu_items=()
    local dev uuid
    while read -r dev uuid; do
        [[ -n "$dev" ]] || continue
        menu_items+=("$dev" "UUID ${uuid}")
    done < <(luks_devices)

    if [[ "${#menu_items[@]}" -eq 0 ]]; then
        warden_msg "No LUKS devices" "No crypto_LUKS devices were found."
        return 0
    fi

    local choice
    choice="$(warden_menu "DANGER ZONE: select a device to erase" "crypto_LUKS devices:" "${menu_items[@]}")" || return 0
    dev="$choice"
    uuid="$(uuid_for_device "$dev")"

    danger_msg "$WARDEN_DANGER_ERASE_EXPLANATION"

    local details_file
    details_file="$(mktemp)"
    {
        echo "Device: ${dev}"
        echo "UUID:   ${uuid}"
        echo
        describe_device_for_erase "$dev"
    } > "$details_file"
    danger_textbox "$details_file"
    rm -f "$details_file"

    # Purely informational -- the answer doesn't gate anything here, it
    # exists to make the person consciously think about it before the
    # real confirmation gate below. Continue regardless of the answer.
    if danger_yesno "Do you have a LUKS header backup of this device stored somewhere OTHER than this device?\n\nWarden cannot verify this itself. If a backup exists and you want this erase to be truly final, that backup will need destroying separately -- an erase here does not touch it.\n\nAnswer honestly either way -- this will not block you from continuing."; then
        log_line "DANGER: person indicated a header backup exists for ${dev} (${uuid}) before erase"
    else
        log_line "DANGER: person indicated NO header backup exists for ${dev} (${uuid}) before erase"
    fi

    if ! confirm_destructive_device_action "$dev" "$uuid" "ERASE" "$WARDEN_DANGER_BACKTITLE"; then
        warden_msg "Cancelled" "Erase was not confirmed. No changes made."
        return 0
    fi

    if danger_yesno "Preview first? Show what would run without actually erasing anything (dry-run)?"; then
        local saved_dry_run="${WARDEN_DRY_RUN}"
        WARDEN_DRY_RUN=1
        run_luks_erase "$dev"
        WARDEN_DRY_RUN="$saved_dry_run"
        if ! danger_yesno "This is the last step. Proceed with the REAL erase of ${dev} now? This cannot be undone."; then
            return 0
        fi
    fi

    if ! run_luks_erase "$dev"; then
        warden_msg "Erase failed" "cryptsetup luksErase did not succeed. Check the session log at ${WARDEN_LOG_FILE}."
        return 0
    fi

    local completion="Erase complete. ${dev} (${uuid}) has had all key slots and its LUKS header destroyed. The bulk data area was not overwritten, but with no key slot remaining, the data on it is permanently unrecoverable. This is the NIST SP 800-88 Purge-level sanitisation this action was for."

    local mapper
    mapper="$(crypttab_mapper_for_uuid "$uuid")"
    if [[ -n "$mapper" ]]; then
        completion+="\n\nThis device still has a /etc/crypttab entry (mapper: ${mapper}). With no key slot left, it can never unlock again -- leaving that entry in place risks hanging the next boot waiting for it. Use menu 12 (Uninstall / revert) to remove its crypttab/fstab entries once you're done with this device."
    fi

    danger_msg "$completion"
}