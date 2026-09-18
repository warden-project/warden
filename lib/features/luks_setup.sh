# shellcheck shell=bash
# lib/features/luks_setup.sh — menu 4: LUKS setup wizard (new device)
#
# Formats a device that isn't LUKS yet, then hands off into the same
# complete_enrolment() logic menu 5 uses, passing along the UUID and
# passphrase just created so nothing has to be re-entered.

# _raw_format_devices — "<devpath> <fstype-or-none>" for every
# disk/partition that is not already crypto_LUKS, with no other
# filtering. Not for direct use -- see candidate_format_devices below.
#
# Uses `lsblk --json` rather than raw/awk column parsing: confirmed on
# real hardware that lsblk's raw mode represents an empty column as
# two adjacent spaces, which awk's default whitespace-run field
# splitting collapses -- silently shifting every later column left and
# excluding blank disks (the primary case this function exists for)
# from the result entirely. JSON has no such ambiguity.
_raw_format_devices() {
    lsblk --json -o PATH,FSTYPE,TYPE 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
for dev in data.get("blockdevices", []):
    if dev.get("type") not in ("disk", "part"):
        continue
    if dev.get("fstype") == "crypto_LUKS":
        continue
    print(dev["path"], dev.get("fstype") or "none")
'
}

# candidate_format_devices — _raw_format_devices, minus anything that
# is or backs root/boot/efi.
#
# Found while interactively testing menu 4 on real hardware: this list
# was showing the whole system disk itself (and its root/boot/efi
# partitions) as formattable, on a machine where they happen to be
# non-LUKS. confirm_destructive_device_action's guard would still have
# refused the actual format, but there's no reason to offer a
# selection that can only ever end in a refusal -- menu 5's equivalent
# list (unmanaged_luks_devices) already filters the same way.
candidate_format_devices() {
    local dev fstype
    while read -r dev fstype; do
        [[ -n "$dev" ]] || continue
        guard_not_system_critical "$dev" || continue
        printf '%s %s\n' "$dev" "$fstype"
    done < <(_raw_format_devices)
}

generate_passphrase() {
    head -c 32 /dev/urandom | base64 | tr -d '=+/\n' | head -c 32
}

# format_luks_device <dev> <passphrase>
#
# Not routed through the generic run_cmd chokepoint: cryptsetup needs
# the passphrase piped on stdin, which run_cmd's argv-array form
# doesn't support. Mirrors run_cmd's own dry-run/logging behaviour by
# hand, but the log line never includes the passphrase value itself.
#
# Confirmed on real hardware (not reproducible against the loop-device
# test harness used in earlier dev-sandbox testing): lsblk/blkid's
# cached view of a device can briefly lag behind cryptsetup actually
# succeeding -- `uuid_for_device` immediately after a bare luksFormat
# reliably returned empty in 5/5 trials, only fixed by waiting for
# udev to catch up. Since this function's only caller (menu 4) queries
# the new UUID right after formatting to hand off into enrolment, an
# empty UUID here would have written a broken `UUID=` crypttab line.
format_luks_device() {
    local dev="$1" passphrase="$2"
    if [[ "${WARDEN_DRY_RUN}" == "1" ]]; then
        log_line "[DRY-RUN] would run: cryptsetup luksFormat --batch-mode ${dev} - (passphrase piped via stdin, not logged)"
        printf '[DRY-RUN] would run: cryptsetup luksFormat --batch-mode %s -\n' "$dev" >&2
        return 0
    fi
    log_line "RUN luksFormat ${dev} (passphrase piped via stdin, not logged)"
    printf '%s' "$passphrase" | cryptsetup luksFormat --batch-mode "$dev" - >>"$WARDEN_LOG_FILE" 2>&1
    local status=$?
    log_line "  -> exit ${status}"
    if [[ "$status" -eq 0 ]]; then
        udevadm settle
    fi
    return "$status"
}

# create_filesystem <dev> <passphrase> <fstype>
#
# Opens the just-formatted device with a throwaway mapper name, builds
# the filesystem, closes it again -- same rationale as
# format_luks_device for handling the passphrase outside run_cmd.
create_filesystem() {
    local dev="$1" passphrase="$2" fstype="$3" tmp_name="warden-setup-$$"
    if [[ "${WARDEN_DRY_RUN}" == "1" ]]; then
        log_line "[DRY-RUN] would open ${dev}, run mkfs.${fstype}, then close it"
        printf '[DRY-RUN] would open %s, create a %s filesystem, then close it\n' "$dev" "$fstype" >&2
        return 0
    fi
    printf '%s' "$passphrase" | cryptsetup open --batch-mode "$dev" "$tmp_name" - >>"$WARDEN_LOG_FILE" 2>&1
    if [[ ! -e "/dev/mapper/${tmp_name}" ]]; then
        log_line "  -> failed to open ${dev} to create filesystem"
        return 1
    fi
    run_cmd "create ${fstype} filesystem on ${dev}" -- "mkfs.${fstype}" "/dev/mapper/${tmp_name}" >/dev/null
    local status=$?
    run_cmd "close ${tmp_name}" -- cryptsetup close "$tmp_name" >/dev/null
    return "$status"
}

feature_luks_setup_menu() {
    local trust
    trust="$(load_trust_config_or_warn)" || return 0
    local pin_type="${trust%%$'\t'*}" pin_config="${trust#*$'\t'}"

    local -a menu_items=()
    local dev fstype
    while read -r dev fstype; do
        [[ -n "$dev" ]] || continue
        menu_items+=("$dev" "existing: ${fstype}")
    done < <(candidate_format_devices)

    if [[ "${#menu_items[@]}" -eq 0 ]]; then
        warden_msg "No candidate devices" "No non-LUKS block devices were found."
        return 0
    fi

    dev="$(warden_menu "Select a device to format" "WARNING: formatting destroys any existing data on the chosen device.\n\nDevices not already LUKS-encrypted:" "${menu_items[@]}")" || return 0

    local identifier
    identifier="$(uuid_for_device "$dev")"
    [[ -z "$identifier" ]] && identifier="$dev"

    if ! confirm_destructive_device_action "$dev" "$identifier" "FORMAT"; then
        warden_msg "Cancelled" "Formatting was not confirmed. No changes made."
        return 0
    fi

    local passphrase
    if warden_yesno "Passphrase" "Generate a strong recovery passphrase automatically?\n\n(Choosing No lets you enter your own.)"; then
        passphrase="$(generate_passphrase)"
        warden_msg "SAVE THIS NOW" "Generated recovery passphrase:\n\n${passphrase}\n\nThis will not be shown again and is never written to the log. Save it somewhere safe before continuing."
        if ! warden_yesno "Confirm" "Have you saved the passphrase above?"; then
            warden_msg "Cancelled" "Aborted -- passphrase was not confirmed saved. No changes made."
            return 0
        fi
    else
        passphrase="$(whiptail --passwordbox "Enter a strong recovery passphrase:" 12 70 3>&1 1>&2 2>&3)" || return 0
    fi

    # Only ask "what should this device hold" at all if ZFS is actually
    # available -- zfsutils-linux is an optional install (menu 1), and
    # someone who never installed it shouldn't be stopped by an extra
    # menu screen for a choice they can't act on. Anyone who hasn't
    # opted into ZFS gets exactly the original ext4-only flow back.
    if is_pkg_installed zfsutils-linux; then
        local fs_kind
        fs_kind="$(warden_menu "Filesystem" "What should this device hold?" \
            filesystem "A plain filesystem (ext4 by default; you can type any mkfs.<type> at the next prompt)" \
            zfs "A single-disk ZFS pool (auto-imports/mounts after unlock; no /etc/fstab entry)")" || return 0

        if [[ "$fs_kind" == "zfs" ]]; then
            luks_setup_zfs_flow "$dev" "$passphrase" "$pin_type" "$pin_config"
            return 0
        fi
    fi

    local fstype
    fstype="$(whiptail --inputbox "Filesystem to create:" 10 60 "ext4" 3>&1 1>&2 2>&3)" || return 0

    if warden_yesno "Preview" "This will:\n\n- cryptsetup luksFormat ${dev}\n- Create a ${fstype} filesystem inside it\n- Then continue into enrolment (mapper name, crypttab/fstab, Clevis bind)\n\nShow this as a dry-run first (no changes made)?"; then
        local saved_dry_run="${WARDEN_DRY_RUN}"
        WARDEN_DRY_RUN=1
        format_luks_device "$dev" "$passphrase"
        create_filesystem "$dev" "$passphrase" "$fstype"
        WARDEN_DRY_RUN="$saved_dry_run"
        if ! warden_yesno "Proceed?" "Proceed with the real format now? This destroys any existing data on ${dev}."; then
            return 0
        fi
    fi

    if ! format_luks_device "$dev" "$passphrase"; then
        warden_msg "Format failed" "cryptsetup luksFormat did not succeed. Check the session log at ${WARDEN_LOG_FILE}."
        return 0
    fi

    if ! create_filesystem "$dev" "$passphrase" "$fstype"; then
        warden_msg "Filesystem creation failed" "The device is now LUKS-formatted, but creating the ${fstype} filesystem did not succeed. Check the session log at ${WARDEN_LOG_FILE}. You can retry filesystem creation manually, or enrol it from menu 5 once fixed."
        return 0
    fi

    local uuid
    uuid="$(uuid_for_device "$dev")"

    local existing_names
    existing_names="$(crypttab_mapper_names | tr '\n' ' ')"
    local mapper
    mapper="$(whiptail --inputbox "Device formatted. Mapper name for this device.\n\nExisting names on this system: ${existing_names:-none}" 12 70 3>&1 1>&2 2>&3)" || return 0
    if ! is_valid_mapper_name "$mapper"; then
        warden_msg "Invalid name" "'${mapper}' is either not a valid name (letters, numbers, -, _ only) or is already in use. The device is formatted -- re-run menu 5 to enrol it with a valid name."
        return 0
    fi

    local mountpoint
    mountpoint="$(whiptail --inputbox "Mountpoint for /dev/mapper/${mapper} (or 'none' to skip adding an fstab entry):" 10 70 3>&1 1>&2 2>&3)" || return 0

    complete_enrolment "$dev" "$uuid" "$mapper" "$mountpoint" "$fstype" "$passphrase" "$pin_type" "$pin_config"
}

# luks_setup_zfs_flow <dev> <passphrase> <pin_type> <pin_config>
#
# Split out from feature_luks_setup_menu because the ZFS path asks for
# the mapper name earlier than the plain-filesystem path does: a
# zpool's name is fixed at creation, this design reuses the mapper
# name as the pool name (one prompt, not two -- see zfs_pool.sh), and
# create_zfs_pool needs that name to open the device under before the
# pool can exist at all. The plain-filesystem path can't reuse this
# ordering: it deliberately opens under a throwaway name, formats, and
# closes again, asking for the real mapper name only once the format
# has already succeeded.
luks_setup_zfs_flow() {
    local dev="$1" passphrase="$2" pin_type="$3" pin_config="$4"

    if ! is_pkg_installed zfsutils-linux; then
        warden_msg "zfsutils-linux not installed" "Install it from menu 1 first."
        return 0
    fi

    local existing_names
    existing_names="$(crypttab_mapper_names | tr '\n' ' ')"
    local mapper
    mapper="$(whiptail --inputbox "Mapper AND zpool name for this device (letters, numbers, -, _ only -- the pool reuses the mapper name).\n\nExisting names on this system: ${existing_names:-none}" 12 70 3>&1 1>&2 2>&3)" || return 0
    if ! is_valid_mapper_name "$mapper"; then
        warden_msg "Invalid name" "'${mapper}' is either not a valid name (letters, numbers, -, _ only) or is already in use."
        return 0
    fi
    if ! is_valid_zpool_name "$mapper"; then
        warden_msg "Invalid zpool name" "'${mapper}' is a valid mapper name but not a valid zpool name (zpool reserves names like mirror/raidz/log/cache/spare, and disallows a leading digit). Choose a different name."
        return 0
    fi

    local mountpoint
    mountpoint="$(whiptail --inputbox "Mountpoint for the ZFS dataset (ZFS pools need an actual path here, not 'none'):" 10 70 "/mnt/${mapper}" 3>&1 1>&2 2>&3)" || return 0
    if [[ -z "$mountpoint" || "$mountpoint" == "none" ]]; then
        warden_msg "Mountpoint required" "ZFS pools need an actual mountpoint in this wizard, not 'none'."
        return 0
    fi

    if warden_yesno "Preview" "This will:\n\n- cryptsetup luksFormat ${dev}\n- Open it as /dev/mapper/${mapper}\n- zpool create -m ${mountpoint} ${mapper} /dev/mapper/${mapper}\n- Then continue into enrolment (crypttab, Clevis bind, boot-time import unit)\n\nShow this as a dry-run first (no changes made)?"; then
        local saved_dry_run="${WARDEN_DRY_RUN}"
        WARDEN_DRY_RUN=1
        format_luks_device "$dev" "$passphrase"
        create_zfs_pool "$dev" "$passphrase" "$mapper" "$mountpoint"
        WARDEN_DRY_RUN="$saved_dry_run"
        if ! warden_yesno "Proceed?" "Proceed with the real format now? This destroys any existing data on ${dev}."; then
            return 0
        fi
    fi

    if ! format_luks_device "$dev" "$passphrase"; then
        warden_msg "Format failed" "cryptsetup luksFormat did not succeed. Check the session log at ${WARDEN_LOG_FILE}."
        return 0
    fi

    if ! create_zfs_pool "$dev" "$passphrase" "$mapper" "$mountpoint"; then
        warden_msg "Pool creation failed" "The device is now LUKS-formatted, but creating the ZFS pool did not succeed. Check the session log at ${WARDEN_LOG_FILE}. You can retry pool creation manually (cryptsetup open, then zpool create), or clean up and re-run this wizard."
        return 0
    fi

    local uuid
    uuid="$(uuid_for_device "$dev")"

    complete_enrolment "$dev" "$uuid" "$mapper" "$mountpoint" "zfs" "$passphrase" "$pin_type" "$pin_config"
}
