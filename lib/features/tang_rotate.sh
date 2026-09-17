# shellcheck shell=bash
# lib/features/tang_rotate.sh — menu 10: rotate this host's Tang server keys
#
# Distinct from menu 8 (rotating a CLIENT's binding): this is for a
# host that runs Tang itself, rotating the server's own signing/
# exchange keys.
#
# NOTE: locate_tangd_rotate_keys() assumes upstream Tang's bundled
# `tangd-rotate-keys` helper is installed at one of a few conventional
# paths. This has not been verified against a real `tang` package
# install in this development environment (tang isn't installed here).
# Verify the actual path/invocation on a real host/VM before relying
# on this; if it's wrong, this menu fails closed with a clear message
# rather than guessing at reimplementing key rotation by hand.

: "${WARDEN_TANG_DB_DIR:=/var/db/tang}"
: "${WARDEN_TANGD_ROTATE_KEYS_CANDIDATES:=/usr/libexec/tangd-rotate-keys /usr/lib/tangd/tangd-rotate-keys}"

locate_tangd_rotate_keys() {
    local c
    for c in ${WARDEN_TANGD_ROTATE_KEYS_CANDIDATES}; do
        [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    command -v tangd-rotate-keys 2>/dev/null
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

rotate_tang_keys() {
    local script
    script="$(locate_tangd_rotate_keys)" || return 2
    run_cmd "rotate Tang keys in ${WARDEN_TANG_DB_DIR}" -- "$script" -d "$WARDEN_TANG_DB_DIR"
}

feature_tang_key_rotate_menu() {
    if ! is_pkg_installed tang; then
        warden_msg "Tang not installed" "This host doesn't run Tang, so there are no server keys to rotate here. (This is different from menu 8, which rotates a client's binding.)"
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

    rotate_tang_keys
    local result=$?
    if [[ "$result" -eq 2 ]]; then
        warden_msg "Rotation helper not found" "Couldn't find tangd-rotate-keys at any expected location. Not guessing at reimplementing key rotation by hand -- see the wiki for the manual procedure, or verify the correct path for this Tang package and let Warden's maintainers know."
        return 0
    elif [[ "$result" -ne 0 ]]; then
        warden_msg "Rotation failed" "tangd-rotate-keys did not succeed. Check the session log at ${WARDEN_LOG_FILE}."
        return 0
    fi

    warden_msg "Rotation complete" "New keys generated; old keys retired (hidden, not deleted).\n\n$(list_tang_keys)"
}
