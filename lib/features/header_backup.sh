# shellcheck shell=bash
# lib/features/header_backup.sh — menu 11: backup LUKS header(s)
#
# A header backup contains wrapped key material and is sensitive --
# Warden reminds of this in the UI itself, not just in docs, and
# refuses to guess where a safe storage location is (that's the
# person's call, same as the /var/lib/tang reminder in menu 2).

: "${WARDEN_HEADER_BACKUP_DIR:=${WARDEN_BACKUP_DIR:-/var/backups/warden}/luks-headers}"

# existing_header_backups <uuid> — paths of any header backups already
# taken for this UUID, one per line.
existing_header_backups() {
    local uuid="$1" f
    for f in "${WARDEN_HEADER_BACKUP_DIR}/${uuid}."*.header; do
        [[ -f "$f" ]] && echo "$f"
    done
    return 0
}

# backup_luks_header <dev> <uuid> — writes a timestamped header backup,
# prints the resulting path on success.
backup_luks_header() {
    local dev="$1" uuid="$2" ts dest
    mkdir -p "$WARDEN_HEADER_BACKUP_DIR"
    chmod 700 "$WARDEN_HEADER_BACKUP_DIR"
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    dest="${WARDEN_HEADER_BACKUP_DIR}/${uuid}.${ts}.header"
    if ! run_cmd "backup LUKS header for ${dev}" -- cryptsetup luksHeaderBackup "$dev" --header-backup-file "$dest" >/dev/null; then
        return 1
    fi
    [[ "${WARDEN_DRY_RUN}" == "1" ]] || chmod 600 "$dest"
    printf '%s' "$dest"
}

feature_header_backup_menu() {
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

    dev="$(warden_menu "Select a device to back up" "crypto_LUKS devices:" "${menu_items[@]}")" || return 0
    uuid="$(uuid_for_device "$dev")"

    local existing
    existing="$(existing_header_backups "$uuid" | tr '\n' ' ')"
    if ! warden_yesno "Header backup" "Device: ${dev}\nUUID: ${uuid}\n\nExisting backups for this device: ${existing:-none}\n\nA header backup contains wrapped key material and is sensitive: store it somewhere the encrypted drive's own failure wouldn't also take out the backup. Warden will not copy it anywhere else for you.\n\nProceed with a new backup now?"; then
        return 0
    fi

    if warden_yesno "Preview first?" "Show what would happen without actually writing a backup (dry-run)?"; then
        local saved_dry_run="${WARDEN_DRY_RUN}"
        WARDEN_DRY_RUN=1
        backup_luks_header "$dev" "$uuid" >/dev/null
        WARDEN_DRY_RUN="$saved_dry_run"
        if ! warden_yesno "Proceed?" "Proceed with the real backup now?"; then
            return 0
        fi
    fi

    local dest
    if ! dest="$(backup_luks_header "$dev" "$uuid")"; then
        warden_msg "Backup failed" "cryptsetup luksHeaderBackup did not succeed. Check the session log at ${WARDEN_LOG_FILE}."
        return 0
    fi

    warden_msg "Backup complete" "Header backup written to:\n\n${dest}\n\nRemember: this file is sensitive and is not copied anywhere else automatically."
}
