# shellcheck shell=bash
# lib/features/luks_enroll.sh — menu 5: LUKS enrolment wizard
#
# Binds an EXISTING, already-formatted crypto_LUKS device to the trust
# configuration built by menu 3, then wires it into crypttab/fstab.
#
# Deliberately excludes any device that is or backs root/boot/efi: root
# unlock is its own deferred, separately-gated feature (see
# docs/original-spec.md), and must never be reachable from this general
# wizard, accidentally or otherwise.

: "${WARDEN_CRYPTTAB:=/etc/crypttab}"
: "${WARDEN_FSTAB:=/etc/fstab}"

# trust_config_has_tailscale <json> — true if any address in a saved
# tang-bindings.json config is Tailscale-flagged.
trust_config_has_tailscale() {
    local json="$1"
    python3 -c '
import json, sys
data = json.loads(sys.argv[1])
sys.exit(0 if any(a.get("is_tailscale") for a in data.get("addresses", [])) else 1)
' "$json"
}

# cryptsetup_dropin_dir <mapper> — the (systemd-escaped) drop-in
# directory for this mapper's systemd-cryptsetup@ unit.
cryptsetup_dropin_dir() {
    local mapper="$1" unit
    unit="$(systemd-escape --template=systemd-cryptsetup@.service "$mapper")"
    printf '%s/%s.d' "${WARDEN_SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}" "$unit"
}

_tailscale_dropin_content() {
    printf '[Unit]\nAfter=tailscale-online.target\nWants=tailscale-online.target\n'
}

# ensure_tailscale_ordering_dropin <mapper> — idempotent: no-op if
# already present with this exact content.
#
# Why this exists: network-online.target only means basic networking
# is up, not that Tailscale has finished connecting, and ordering
# against tailscaled.service alone isn't reliable either -- a Clevis
# unlock attempt against a Tailscale-only Tang address can run before
# the tailnet is actually usable without this. See the wiki.
ensure_tailscale_ordering_dropin() {
    local mapper="$1" dir file
    dir="$(cryptsetup_dropin_dir "$mapper")"
    file="${dir}/override.conf"

    if [[ -f "$file" ]] && [[ "$(cat "$file")" == "$(_tailscale_dropin_content)" ]]; then
        log_line "TAILSCALE-DROPIN: already present for ${mapper}, skipping"
        return 0
    fi

    if [[ "${WARDEN_DRY_RUN}" == "1" ]]; then
        log_line "[DRY-RUN] would write ${file}"
        printf '[DRY-RUN] would write %s:\n%s\n' "$file" "$(_tailscale_dropin_content)" >&2
        return 0
    fi

    mkdir -p "$dir"
    [[ -f "$file" ]] && backup_file "$file" >/dev/null
    local before after
    before="$(mktemp)"; after="$(mktemp)"
    if [[ -f "$file" ]]; then
        cp -p "$file" "$before"
    else
        : > "$before"
    fi
    _tailscale_dropin_content > "$file"
    cp -p "$file" "$after"
    log_diff "$file" "$before" "$after"
    rm -f "$before" "$after"

    run_cmd "reload systemd units" -- systemctl daemon-reload
}

# unmanaged_luks_devices — "<devpath> <uuid>" pairs for crypto_LUKS
# devices that have no /etc/crypttab entry AND do not back root/boot/efi.
unmanaged_luks_devices() {
    local dev uuid
    while read -r dev uuid; do
        [[ -n "$dev" ]] || continue
        [[ -z "$(crypttab_mapper_for_uuid "$uuid")" ]] || continue
        guard_not_system_critical "$dev" || continue
        printf '%s %s\n' "$dev" "$uuid"
    done < <(luks_devices)
}

# is_valid_mapper_name <name> — safe identifier, not already in use.
is_valid_mapper_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    ! crypttab_mapper_names | grep -qxF "$name"
}

build_crypttab_line() {
    local mapper="$1" uuid="$2"
    printf '%s UUID=%s none luks,_netdev' "$mapper" "$uuid"
}

build_fstab_line() {
    local mapper="$1" mountpoint="$2" fstype="$3"
    printf '/dev/mapper/%s %s %s defaults,nofail 0 2' "$mapper" "$mountpoint" "$fstype"
}

# run_clevis_luks_bind <dev> <existing_passphrase> <pin_type> <pin_config>
#
# The existing passphrase is written to a mode-600 temp file (never
# passed as a command-line argument, never logged -- run_cmd only ever
# sees/logs the tempfile *path*) and shredded immediately after use,
# whether the bind succeeds or fails.
run_clevis_luks_bind() {
    local dev="$1" passphrase="$2" pin_type="$3" pin_config="$4"
    local keyfile status
    keyfile="$(mktemp)"
    chmod 600 "$keyfile"
    printf '%s' "$passphrase" > "$keyfile"
    run_cmd "bind clevis ${pin_type} pin to ${dev}" -- clevis luks bind -y -f -k "$keyfile" -d "$dev" "$pin_type" "$pin_config"
    status=$?
    shred -u "$keyfile" 2>/dev/null || rm -f "$keyfile"
    return "$status"
}

# test_unlock_and_cleanup <dev> — binds a throwaway mapper name to
# verify the binding actually works, then tears it down. Prints "ok"
# or "failed" as the ONLY thing on stdout (run_cmd's own captured
# command output is redirected away here) -- callers capture this via
# command substitution, so anything else on stdout would corrupt the
# signal they're matching against.
test_unlock_and_cleanup() {
    local dev="$1" test_name="warden-test-$$"
    if run_cmd "test-unlock ${dev}" -- clevis luks unlock -d "$dev" -n "$test_name" >/dev/null; then
        if [[ -e "/dev/mapper/${test_name}" ]]; then
            run_cmd "close test mapping ${test_name}" -- cryptsetup close "$test_name" >/dev/null
            echo "ok"
            return
        fi
    fi
    echo "failed"
}

feature_luks_enrol_menu() {
    local trust
    trust="$(load_trust_config_or_warn)" || return 0
    local pin_type="${trust%%$'\t'*}" pin_config="${trust#*$'\t'}"

    local -a menu_items=()
    local dev uuid
    while read -r dev uuid; do
        [[ -n "$dev" ]] || continue
        menu_items+=("$dev" "UUID ${uuid}")
    done < <(unmanaged_luks_devices)

    if [[ "${#menu_items[@]}" -eq 0 ]]; then
        warden_msg "Nothing to enrol" "No unmanaged crypto_LUKS devices were found (every crypto_LUKS device is either already in /etc/crypttab, or excluded because it's this system's root/boot/efi device -- see the wiki for root-drive unlock, which is a separate, not-yet-built feature)."
        return 0
    fi

    dev="$(warden_menu "Select a device to enrol" "Unmanaged crypto_LUKS devices:" "${menu_items[@]}")" || return 0
    uuid="$(uuid_for_device "$dev")"

    if ! guard_not_system_critical "$dev"; then
        # Should be unreachable (unmanaged_luks_devices already filters
        # this out), but never trust a stale list over a fresh check.
        warden_msg "Refused" "${dev} is or backs root/boot/efi. Refusing."
        return 0
    fi

    local existing_names
    existing_names="$(crypttab_mapper_names | tr '\n' ' ')"
    local mapper
    mapper="$(whiptail --inputbox "Mapper name for this device.\n\nExisting names on this system: ${existing_names:-none}" 12 70 3>&1 1>&2 2>&3)" || return 0
    if ! is_valid_mapper_name "$mapper"; then
        warden_msg "Invalid name" "'${mapper}' is either not a valid name (letters, numbers, -, _ only) or is already in use."
        return 0
    fi

    local mountpoint
    mountpoint="$(whiptail --inputbox "Mountpoint for /dev/mapper/${mapper} (or 'none' to skip adding an fstab entry):" 10 70 3>&1 1>&2 2>&3)" || return 0

    local fstype="ext4"
    if [[ "$mountpoint" != "none" ]]; then
        fstype="$(whiptail --inputbox "Filesystem type on this device:" 10 60 "ext4" 3>&1 1>&2 2>&3)" || return 0
    fi

    local passphrase
    passphrase="$(whiptail --passwordbox "Enter this device's EXISTING LUKS passphrase, to authorise adding the new Clevis binding:" 12 70 3>&1 1>&2 2>&3)" || return 0

    complete_enrolment "$dev" "$uuid" "$mapper" "$mountpoint" "$fstype" "$passphrase" "$pin_type" "$pin_config"
}

# complete_enrolment <dev> <uuid> <mapper> <mountpoint|none> <fstype> <passphrase> <pin_type> <pin_config>
#
# The actual crypttab/fstab/bind/test-unlock sequence, shared by this
# wizard and the LUKS setup wizard (menu 4) once it hands off a
# freshly-formatted device -- so a device is only ever enrolled one
# way, and menu 4 never has to re-prompt for a passphrase it just set.
#
# Confirmed on real hardware via an actual reboot test: build_crypttab_line's
# `_netdev` option makes systemd route the generated systemd-cryptsetup@
# unit exclusively through remote-cryptsetup.target, NOT cryptsetup.target
# -- and remote-cryptsetup.target is disabled by default on Ubuntu. A
# device with an fstab entry still unlocks at boot (the fstab-generator
# wires a direct dependency from that mount unit onto the specific
# cryptsetup unit, bypassing remote-cryptsetup.target entirely), but a
# device enrolled with mountpoint "none" has nothing else to pull that
# unit in -- it silently never even attempts to unlock, with no error
# anywhere, even though clevis-luks-askpass.path is enabled and correct.
# ensure_systemd_unit_enabled below closes that gap unconditionally, not
# just when mountpoint is "none": it's a one-line, no-downside fix that
# doesn't depend on correctly predicting every case that needs it.
complete_enrolment() {
    local dev="$1" uuid="$2" mapper="$3" mountpoint="$4" fstype="$5" passphrase="$6" pin_type="$7" pin_config="$8"

    local crypttab_line fstab_line
    crypttab_line="$(build_crypttab_line "$mapper" "$uuid")"
    if [[ "$mountpoint" != "none" ]]; then
        fstab_line="$(build_fstab_line "$mapper" "$mountpoint" "$fstype")"
    fi

    local saved_config trust_summary needs_tailscale_dropin=0
    saved_config="$(load_bindings_config)"
    trust_summary="$(describe_saved_bindings "$saved_config")"
    if trust_config_has_tailscale "$saved_config"; then
        needs_tailscale_dropin=1
    fi

    local preview="This will:\n\n- Add to ${WARDEN_CRYPTTAB}:\n  ${crypttab_line}\n"
    [[ -n "${fstab_line:-}" ]] && preview+="\n- Add to ${WARDEN_FSTAB}:\n  ${fstab_line}\n"
    preview+="\n- Bind Clevis to ${dev} using:\n${trust_summary}\n- Test-unlock and clean up the test mapping"
    if [[ "$needs_tailscale_dropin" == "1" ]]; then
        preview+="\n- Add a systemd ordering drop-in so this device's unlock waits for Tailscale (one of the trusted addresses is a Tailscale address)"
    fi

    if warden_yesno "Preview" "${preview}\n\nShow this as a dry-run first (no changes made)?"; then
        local saved_dry_run="${WARDEN_DRY_RUN}"
        WARDEN_DRY_RUN=1
        run_clevis_luks_bind "$dev" "$passphrase" "$pin_type" "$pin_config" >/dev/null
        WARDEN_DRY_RUN="$saved_dry_run"
        if ! warden_yesno "Proceed?" "Proceed with the real enrolment now?"; then
            return 0
        fi
    fi

    append_line_if_missing "$WARDEN_CRYPTTAB" "$crypttab_line"
    [[ -n "${fstab_line:-}" ]] && append_line_if_missing "$WARDEN_FSTAB" "$fstab_line"
    ensure_systemd_unit_enabled "remote-cryptsetup.target"
    [[ "$needs_tailscale_dropin" == "1" ]] && ensure_tailscale_ordering_dropin "$mapper"

    if ! run_clevis_luks_bind "$dev" "$passphrase" "$pin_type" "$pin_config" >/dev/null; then
        warden_msg "Bind failed" "clevis luks bind did not succeed. Check the session log at ${WARDEN_LOG_FILE}. The crypttab/fstab entries were still added -- remove them manually if you're abandoning this device."
        return 0
    fi

    local unlock_result
    unlock_result="$(test_unlock_and_cleanup "$dev")"
    if [[ "$unlock_result" == "ok" ]]; then
        local msg="${dev} is bound and crypttab/fstab are updated. The test-unlock succeeded, so this should unlock automatically at boot once the late-boot unlocker (menu 6) is enabled."
        [[ "$needs_tailscale_dropin" == "1" ]] && msg+="\n\nA systemd ordering drop-in was also added so unlock waits for Tailscale to be up, not just basic networking."
        warden_msg "Enrolment complete" "$msg"
    else
        warden_msg "Bind succeeded, but test-unlock failed" "The Clevis binding was added, but the test-unlock did not succeed. Do not reboot relying on this yet -- check network/Tang reachability and the session log at ${WARDEN_LOG_FILE}."
    fi
}

# load_trust_config_or_warn — echoes "pin_type<TAB>pin_config" on
# success. On failure, shows the appropriate whiptail message itself
# and returns 1, so both wizards get identical, single-sourced wording.
load_trust_config_or_warn() {
    if ! command -v clevis >/dev/null 2>&1; then
        warden_msg "Clevis not installed" "Clevis isn't installed on this host yet. Install it from menu 1 first."
        return 1
    fi
    local trust_config
    trust_config="$(load_bindings_config)"
    if [[ -z "$trust_config" ]]; then
        warden_msg "No trust configuration" "No Tang trust configuration has been saved yet. Run menu 3 first."
        return 1
    fi
    local pin_type pin_config
    pin_type="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["pin_type"])' <<<"$trust_config")"
    pin_config="$(python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["pin_config"]))' <<<"$trust_config")"
    printf '%s\t%s\n' "$pin_type" "$pin_config"
}
