# shellcheck shell=bash
# lib/features/status.sh — menu 7: read-only status dashboard
#
# Every function here is read-only by design (no run_cmd calls) --
# this menu item must never mutate state, only report it.
#
# luks_devices/crypttab_mapper_for_uuid/fstab_has_mapper live in
# lib/core/crypt_inventory.sh, shared with the enrolment wizard.

# clevis_pins_for_device <devpath> — raw `clevis luks list` output, or
# empty if clevis isn't installed or the device has no bindings.
# Always returns 0 (see load_bindings_config's comment for why this
# matters): `clevis luks list` exits non-zero for the very common,
# entirely normal case of a device with no bindings yet, and this is
# called via bare assignment from several places under bin/warden's
# `set -e`.
clevis_pins_for_device() {
    local dev="$1"
    command -v clevis >/dev/null 2>&1 || return 0
    clevis luks list -d "$dev" 2>/dev/null
    return 0
}

# extract_tang_urls <clevis_luks_list_output> — unique tang server URLs
# referenced by any pin (single tang, or nested inside sss), one per line.
extract_tang_urls() {
    local text="$1"
    grep -oE '"url"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"$text" \
        | sed -E 's/.*"url"[[:space:]]*:[[:space:]]*"([^"]+)"/\1/' \
        | sort -u
}

# tailscale_ordering_dropins — paths of any systemd-cryptsetup@ drop-ins
# that order against tailscale-online.target, one per line.
tailscale_ordering_dropins() {
    local dir="${WARDEN_SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
    local f
    for f in "${dir}"/systemd-cryptsetup@*.service.d/*.conf; do
        [[ -f "$f" ]] || continue
        grep -ql 'tailscale-online.target' "$f" && echo "$f"
    done
    return 0
}

# unit_state <unit> — "active", "inactive", or "not present".
unit_state() {
    local unit="$1"
    if ! systemctl list-unit-files "$unit" --no-legend 2>/dev/null | grep -q .; then
        echo "not present"
        return
    fi
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        echo "active"
    else
        echo "inactive"
    fi
}

render_status_report() {
    local dev uuid mapper pins url reach
    local -A seen_urls=()

    echo "=== Managed devices ==="
    local any=0
    while read -r dev uuid; do
        [[ -n "$dev" ]] || continue
        any=1
        mapper="$(crypttab_mapper_for_uuid "$uuid")"
        echo "Device:   $dev"
        echo "UUID:     $uuid"
        if [[ -n "$mapper" ]]; then
            echo "Mapper:   $mapper (in /etc/crypttab)"
            local zfs_unit="warden-zfs-import@${mapper}.service"
            if is_systemd_unit_enabled "$zfs_unit" 2>/dev/null; then
                # Not unit_state here: confirmed on real hardware that
                # `systemctl list-unit-files <specific-instance>` (what
                # unit_state's existence check relies on) only ever
                # lists the template itself (warden-zfs-import@.service),
                # never a specific instance name -- so it always
                # reports "not present" for a template-instantiated
                # unit regardless of real state. Already known to exist
                # here (that's what the enabled check above just
                # confirmed), so is-active alone is enough.
                local zfs_active="inactive"
                systemctl is-active --quiet "$zfs_unit" 2>/dev/null && zfs_active="active"
                echo "ZFS:      ${zfs_unit} enabled, state: ${zfs_active}"
                # zfs list's default tab-separated output renders as
                # visually cramped/misaligned in whiptail's textbox
                # (confirmed on real hardware); a single space between
                # fields reads cleanly instead.
                describe_zfs_pool_status "$mapper" | tr '\t' ' ' | sed 's/^/          /'
            elif fstab_has_mapper "$mapper"; then
                echo "fstab:    entry present"
            else
                echo "fstab:    NO entry for /dev/mapper/${mapper}"
            fi
            if [[ -e "/dev/mapper/${mapper}" ]]; then
                echo "State:    unlocked (mapper active)"
            else
                echo "State:    locked (mapper not active)"
            fi
        else
            echo "Mapper:   (none -- not in /etc/crypttab, unmanaged)"
        fi

        pins="$(clevis_pins_for_device "$dev")"
        if [[ -n "$pins" ]]; then
            echo "Clevis bindings:"
            echo "  ${pins//$'\n'/$'\n  '}"
            while read -r url; do
                [[ -n "$url" ]] && seen_urls["$url"]=1
            done < <(extract_tang_urls "$pins")
        elif command -v clevis >/dev/null 2>&1; then
            echo "Clevis bindings: none"
        else
            echo "Clevis bindings: (clevis not installed)"
        fi
        echo
    done < <(luks_devices)
    [[ "$any" == "1" ]] || echo "(no crypto_LUKS devices found)"

    echo "=== Tang server reachability ==="
    if [[ "${#seen_urls[@]}" -eq 0 ]]; then
        echo "(no Tang servers referenced by any current binding)"
    else
        for url in "${!seen_urls[@]}"; do
            reach="$(check_tang_reachability "$url")"
            printf '%-45s %s\n' "$url" "$reach"
        done
    fi
    echo

    echo "=== Service status ==="
    if is_pkg_installed tang; then
        printf 'tangd.socket:              %s\n' "$(unit_state tangd.socket)"
    else
        echo "tangd.socket:              (tang not installed)"
    fi
    if is_pkg_installed clevis-systemd; then
        printf 'clevis-luks-askpass.path:  %s\n' "$(unit_state clevis-luks-askpass.path)"
    else
        echo "clevis-luks-askpass.path:  (clevis-systemd not installed)"
    fi
    echo

    echo "=== Tailscale ordering drop-ins ==="
    local dropin any_dropin=0
    while read -r dropin; do
        [[ -n "$dropin" ]] || continue
        any_dropin=1
        echo "$dropin"
    done < <(tailscale_ordering_dropins)
    [[ "$any_dropin" == "1" ]] || echo "(none configured)"
}

feature_status_dashboard() {
    local tmpfile
    tmpfile="$(mktemp)"
    render_status_report > "$tmpfile"
    whiptail --title "Warden -- Status dashboard" --scrolltext --textbox "$tmpfile" 30 100
    rm -f "$tmpfile"
}
