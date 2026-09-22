# shellcheck shell=bash
# lib/features/health_check.sh — menu 9 / `warden check`: a single
# pass/fail health check across everything Warden has configured.
#
# Read-only, like the status dashboard (menu 8) -- this must never
# mutate state, only report it. Deliberately composition, not new
# logic: every check here reuses a primitive menu 8 or menu 6 already
# uses and already has tests for, rather than re-implementing any of
# it. See docs/future-work.md's "A single health-check / self-test
# action" for why this exists: menu 8 only shows Tang reachability for
# servers a currently-bound device already references, and there was
# no single place confirming TPM2 hardware/packages are still present
# or checking root-unlock's drift without a separate trip to menu 6.

# all_configured_pins_text — the raw `clevis luks list` text for every
# managed secondary device plus root (if root is LUKS-encrypted),
# concatenated. The one place enumerating devices for this file, so
# the Tang-URL and TPM2 checks below both scan the same source.
all_configured_pins_text() {
    local dev uuid mapper
    while read -r dev uuid mapper; do
        [[ -n "$dev" ]] || continue
        clevis_pins_for_device "$dev"
    done < <(managed_luks_devices)

    local root_dev
    root_dev="$(resolve_root_luks_device)"
    [[ -n "$root_dev" ]] && clevis_pins_for_device "$root_dev"
    return 0
}

# health_check_tang <pins_text> — PASS/FAIL line per unique Tang URL
# referenced by any current binding (secondary or root). Returns 1 if
# any is unreachable.
health_check_tang() {
    local pins_text="$1" url reach failed=0
    local urls
    urls="$(extract_tang_urls "$pins_text")"
    if [[ -z "$urls" ]]; then
        printf 'Tang: (no Tang bindings configured)\n'
        return 0
    fi
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        reach="$(check_tang_reachability "$url")"
        if [[ "$reach" == "unreachable" ]]; then
            printf 'FAIL Tang %s: %s\n' "$url" "$reach"
            failed=1
        else
            printf 'PASS Tang %s: %s\n' "$url" "$reach"
        fi
    done <<<"$urls"
    return "$failed"
}

# health_check_tpm2 <pins_text> — PASS/FAIL for TPM2 hardware/package
# presence, only checked at all if some binding actually uses a tpm2
# pin. A plain substring check deliberately, not pintype-specific
# parsing: a tpm2 pin shows up as the literal word "tpm2" whether it's
# the top-level pintype or nested inside an sss config's "pins" object
# (see build_sss_pin_config), so this catches both the same way
# extract_tang_urls already treats "url" fields the same regardless of
# nesting.
health_check_tpm2() {
    local pins_text="$1"
    if [[ "$pins_text" != *tpm2* ]]; then
        printf 'TPM2: (no TPM2 bindings configured)\n'
        return 0
    fi
    if ! is_tpm2_present; then
        printf 'FAIL TPM2: a tpm2 binding exists, but no TPM2 device node (/dev/tpm0 or /dev/tpmrm0) is present\n'
        return 1
    fi
    if ! is_pkg_installed clevis-tpm2; then
        printf 'FAIL TPM2: a tpm2 binding exists, but the clevis-tpm2 package is not installed\n'
        return 1
    fi
    printf 'PASS TPM2: hardware present, clevis-tpm2 installed\n'
    return 0
}

# health_check_zfs — PASS/FAIL per managed secondary device backed by a
# ZFS pool, checking its boot-time import unit is both enabled and
# active. Root-unlock never supports ZFS, so this only ever looks at
# secondary devices (managed_luks_devices already excludes root).
health_check_zfs() {
    local dev uuid mapper any=0 failed=0 unit
    # shellcheck disable=SC2034  # uuid is unused here but must be consumed to split managed_luks_devices' 3 columns correctly
    while read -r dev uuid mapper; do
        [[ -n "$dev" ]] || continue
        is_zfs_pool_member "$dev" || continue
        any=1
        unit="warden-zfs-import@${mapper}.service"
        if is_systemd_unit_enabled "$unit" 2>/dev/null && is_systemd_unit_active "$unit" 2>/dev/null; then
            printf 'PASS ZFS %s (%s): import unit enabled and active\n' "$mapper" "$dev"
        else
            printf 'FAIL ZFS %s (%s): import unit not both enabled and active\n' "$mapper" "$dev"
            failed=1
        fi
    done < <(managed_luks_devices)
    [[ "$any" == "1" ]] || printf 'ZFS: (no ZFS-backed devices configured)\n'
    return "$failed"
}

# health_check_late_boot — PASS/FAIL for the late-boot unlocker path
# (clevis-luks-askpass.path), only checked if clevis-systemd is
# installed at all.
health_check_late_boot() {
    if ! is_pkg_installed clevis-systemd; then
        printf 'Late-boot unlocker: (clevis-systemd not installed)\n'
        return 0
    fi
    if is_systemd_unit_active clevis-luks-askpass.path 2>/dev/null; then
        printf 'PASS Late-boot unlocker: clevis-luks-askpass.path is active\n'
        return 0
    fi
    printf 'FAIL Late-boot unlocker: clevis-systemd is installed, but clevis-luks-askpass.path is not active\n'
    return 1
}

# health_check_root_drift — WARN, not FAIL: confirmed elsewhere (see
# docs/future-work.md and root_unlock_initramfs_drift_status's own
# comment) that drift alone never invalidates a binding, it only means
# the recovery kit is stale. Still returns 1 so it counts toward
# "needs attention" overall, just phrased as a warning, not a failure.
health_check_root_drift() {
    if ! is_root_unlock_enabled; then
        printf 'Root-drive unlock: (not enabled)\n'
        return 0
    fi
    local drift
    drift="$(root_unlock_initramfs_drift_status)"
    if [[ "$drift" == *"DRIFT DETECTED"* ]]; then
        printf 'WARN Root-drive unlock: recovery kit is stale -- run Snapshot (menu 6)\n'
        return 1
    fi
    printf 'PASS Root-drive unlock: recovery kit is up to date\n'
    return 0
}

# render_health_check_report — the full report, plus an overall exit
# status: 0 if every check passed, 1 if anything needs attention (a
# real failure, or root-unlock drift). Meant to be used identically
# from the interactive menu and non-interactively (`warden check`) --
# exactly the same text and exit-code contract either way, so there is
# only one implementation to keep correct, not two that could drift
# apart.
render_health_check_report() {
    local pins_text
    pins_text="$(all_configured_pins_text)"

    local overall=0
    echo "=== Warden health check ==="
    echo
    health_check_tang "$pins_text" || overall=1
    health_check_tpm2 "$pins_text" || overall=1
    health_check_zfs || overall=1
    health_check_late_boot || overall=1
    health_check_root_drift || overall=1
    echo
    if [[ "$overall" == "0" ]]; then
        echo "Overall: OK -- nothing needs attention."
    else
        echo "Overall: one or more checks above need attention."
    fi
    return "$overall"
}

# feature_health_check_menu — menu 9: the interactive view of the
# same report `warden check` prints non-interactively.
feature_health_check_menu() {
    local tmpfile
    tmpfile="$(mktemp)"
    render_health_check_report > "$tmpfile"
    # See warden_msg's comment in lib/tui/menu.sh: Escape must never
    # crash the tool, even on a read-only informational screen.
    whiptail --title "Warden -- Health check" --scrolltext --textbox "$tmpfile" 30 100 || true
    rm -f "$tmpfile"
}
