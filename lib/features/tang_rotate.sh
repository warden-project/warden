# shellcheck shell=bash
# lib/features/tang_rotate.sh — menu 12: rotate this host's Tang server keys
#
# Distinct from menu 10 (rotating a CLIENT's binding): this is for a
# host that runs Tang itself, rotating the server's own signing/
# exchange keys.
#
# Confirmed on real hardware (Ubuntu 24.04): the `tang` package does
# NOT ship a `tangd-rotate-keys` convenience script at all (checked
# `dpkg -L tang` directly), even though upstream's own man page
# references one -- it's apparently not packaged for this distro.
# locate_tangd_rotate_keys() still checks for it first (in case a
# future package version, or a manually-installed one, provides it),
# but rotate_tang_keys() falls back to the documented manual procedure
# from `man tang`'s KEY ROTATION section rather than failing outright.
# Also confirmed on real hardware: Ubuntu's tangd@.service actually
# uses /var/lib/tang as its key database directory, not /var/db/tang
# (the path upstream's own docs use in examples, and what this file
# originally assumed before being tested against a real install).

: "${WARDEN_TANG_DB_DIR:=/var/lib/tang}"
: "${WARDEN_TANGD_ROTATE_KEYS_CANDIDATES:=/usr/libexec/tangd-rotate-keys /usr/lib/tangd/tangd-rotate-keys}"

locate_tangd_rotate_keys() {
    local c
    for c in ${WARDEN_TANGD_ROTATE_KEYS_CANDIDATES}; do
        [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    command -v tangd-rotate-keys 2>/dev/null
    return 0
}

# list_tang_keys — every key file in the Tang db dir, one per line,
# flagged as visible (advertised) or hidden (retired but still usable
# for existing bindings).
list_tang_keys() {
    local f base
    # A plain "*" glob excludes dotfiles, but hidden/retired keys are
    # exactly the dotfiles -- shopt dotglob (scoped locally) so both
    # visible and hidden keys are actually listed.
    local old_dotglob
    old_dotglob="$(shopt -p dotglob)"
    shopt -s dotglob
    for f in "${WARDEN_TANG_DB_DIR}"/*; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        case "$base" in
            .*) printf '%s (hidden/retired)\n' "$base" ;;
            *) printf '%s (visible/advertised)\n' "$base" ;;
        esac
    done
    eval "$old_dotglob"
}

# current_tang_key_files <dir> — every visible (non-hidden) *.jwk file
# in the db dir, one per line: the set that rotation will retire.
current_tang_key_files() {
    local dir="$1" f
    for f in "${dir}"/*.jwk; do
        [[ -f "$f" ]] && printf '%s\n' "$f"
    done
    return 0
}

# generate_tang_key <alg> <dir> — writes a new key file with a unique
# name; ownership/permissions matching the db directory itself (real
# tangd key files are owned by the _tang service user, mode 440 -- a
# root-created file here would otherwise end up root-owned, mismatched
# with every existing key).
generate_tang_key() {
    local alg="$1" dir="$2" name owner
    name="${dir}/$(date -u +%Y%m%dT%H%M%SZ)-$$-${alg}.jwk"
    if [[ "${WARDEN_DRY_RUN}" == "1" ]]; then
        log_line "[DRY-RUN] would run: jose jwk gen -i '{\"alg\":\"${alg}\"}' -o ${name}, then match ownership/permissions to ${dir}"
        printf '[DRY-RUN] would generate a new %s key at %s\n' "$alg" "$name" >&2
        return 0
    fi
    run_cmd "generate new ${alg} tang key" -- jose jwk gen -i "{\"alg\":\"${alg}\"}" -o "$name" >/dev/null || return 1
    owner="$(stat -c '%U:%G' "$dir")"
    run_cmd "match ownership of ${name} to ${dir}" -- chown "$owner" "$name"
    run_cmd "restrict permissions on ${name}" -- chmod 440 "$name"
}

# rotate_tang_keys_manual <dir> — the documented manual procedure from
# `man tang`'s KEY ROTATION section: generate new sig+exchange keys,
# then hide (never delete) whatever was visible before. Tang picks up
# changes immediately; no restart needed.
rotate_tang_keys_manual() {
    local dir="$1"
    local -a old_keys=()
    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] && old_keys+=("$f")
    done < <(current_tang_key_files "$dir")

    generate_tang_key "ES512" "$dir" || return 1
    generate_tang_key "ECMR" "$dir" || return 1

    for f in "${old_keys[@]}"; do
        local base
        base="$(basename "$f")"
        if [[ "${WARDEN_DRY_RUN}" == "1" ]]; then
            log_line "[DRY-RUN] would hide ${f} as ${dir}/.${base}"
            continue
        fi
        run_cmd "retire old key ${f}" -- mv "$f" "${dir}/.${base}"
    done
}

rotate_tang_keys() {
    local script
    script="$(locate_tangd_rotate_keys)"
    if [[ -n "$script" ]]; then
        run_cmd "rotate Tang keys in ${WARDEN_TANG_DB_DIR} via ${script}" -- "$script" -d "$WARDEN_TANG_DB_DIR"
        return $?
    fi
    rotate_tang_keys_manual "$WARDEN_TANG_DB_DIR"
}

feature_tang_key_rotate_menu() {
    if ! is_pkg_installed tang; then
        warden_msg "Tang not installed" "This host doesn't run Tang, so there are no server keys to rotate here. (This is different from menu 10, which rotates a client's binding.)"
        return 0
    fi

    local before
    before="$(list_tang_keys)"
    warden_msg "Current keys" "${before:-(no key files found in ${WARDEN_TANG_DB_DIR})}"

    if ! warden_yesno "Rotate Tang server keys" "This generates new signing/exchange keys and retires (hides, does not delete) the current ones.\n\nOld keys are kept so existing client bindings keep working -- new bindings will use the new keys. Re-bind clients over time and clean up old keys only once nothing depends on them anymore.\n\nProceed?"; then
        return 0
    fi

    if warden_yesno "Preview first?" "Show what would run without actually rotating keys (dry-run)?"; then
        local saved_dry_run="${WARDEN_DRY_RUN}"
        WARDEN_DRY_RUN=1
        rotate_tang_keys
        WARDEN_DRY_RUN="$saved_dry_run"
        if ! warden_yesno "Proceed?" "Proceed with the real rotation now?"; then
            return 0
        fi
    fi

    if ! rotate_tang_keys; then
        warden_msg "Rotation failed" "Key rotation did not succeed. Check the session log at ${WARDEN_LOG_FILE}."
        return 0
    fi

    warden_msg "Rotation complete" "New keys generated; old keys retired (hidden, not deleted). Tang picks this up immediately -- no restart needed.\n\n$(list_tang_keys)"
}
