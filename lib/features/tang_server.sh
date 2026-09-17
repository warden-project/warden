# shellcheck shell=bash
# lib/features/tang_server.sh — menu 2: configure the local Tang server
#
# Writes port config as a systemd drop-in (the equivalent of what
# `systemctl edit tangd.socket` produces) rather than editing the
# shipped unit file, and rather than shelling out to the interactive
# `systemctl edit`, so the exact change is a plain file write that logs
# and diffs like everything else Warden touches.

: "${WARDEN_TANGD_SOCKET_UNIT:=tangd.socket}"

_tangd_dropin_dir() {
    printf '%s/tangd.socket.d' "${WARDEN_SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
}

_tangd_dropin_file() {
    printf '%s/override.conf' "$(_tangd_dropin_dir)"
}

# configured_tangd_port — the port this host's own tangd.socket is set
# to via Warden's drop-in, or 80 (tangd's conventional default) if none.
configured_tangd_port() {
    local file port
    file="$(_tangd_dropin_file)"
    if [[ -f "$file" ]]; then
        port="$(grep -oE '^ListenStream=[0-9]+$' "$file" | tail -n1 | cut -d= -f2)"
    fi
    echo "${port:-80}"
}

is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

_tangd_dropin_content() {
    local port="$1"
    printf '[Socket]\nListenStream=\nListenStream=%s\n' "$port"
}

# tangd_port_dropin_matches <port> — true if the drop-in already
# contains exactly this port config (idempotency check).
tangd_port_dropin_matches() {
    local port="$1" file
    file="$(_tangd_dropin_file)"
    [[ -f "$file" ]] || return 1
    [[ "$(cat "$file")" == "$(_tangd_dropin_content "$port")" ]]
}

# ensure_tangd_port <port> — idempotent: no-op if already set to this port.
ensure_tangd_port() {
    local port="$1" dir file
    dir="$(_tangd_dropin_dir)"
    file="$(_tangd_dropin_file)"

    if tangd_port_dropin_matches "$port"; then
        log_line "TANGD: port already set to ${port}, skipping"
        return 0
    fi

    if [[ "${WARDEN_DRY_RUN}" == "1" ]]; then
        log_line "[DRY-RUN] would write ${file} setting ListenStream=${port}"
        printf '[DRY-RUN] would write %s:\n%s\n' "$file" "$(_tangd_dropin_content "$port")" >&2
        return 0
    fi

    mkdir -p "$dir"
    if [[ -f "$file" ]]; then
        backup_file "$file" >/dev/null
    fi
    local before after
    before="$(mktemp)"; after="$(mktemp)"
    [[ -f "$file" ]] && cp -p "$file" "$before" || : > "$before"
    _tangd_dropin_content "$port" > "$file"
    cp -p "$file" "$after"
    log_diff "$file" "$before" "$after"
    rm -f "$before" "$after"

    run_cmd "reload systemd units" -- systemctl daemon-reload
}

is_ufw_active() {
    command -v ufw >/dev/null 2>&1 || return 1
    ufw status 2>/dev/null | head -n1 | grep -q '^Status: active'
}

ufw_allows_port() {
    local port="$1"
    ufw status 2>/dev/null | grep -qE "^${port}(/tcp)?[[:space:]]+ALLOW"
}

ensure_ufw_allows_port() {
    local port="$1"
    if ufw_allows_port "$port"; then
        log_line "UFW: port ${port} already allowed, skipping"
        return 0
    fi
    run_cmd "allow port ${port}/tcp through ufw" -- ufw allow "${port}/tcp"
}

# verify_tang_local <port> — curl the local /adv endpoint. Prints
# "ok" or "failed" and logs the outcome either way.
verify_tang_local() {
    local port="$1"
    if curl -sf -m 3 "http://localhost:${port}/adv" >/dev/null 2>&1; then
        log_line "VERIFY: tang responded on localhost:${port}"
        echo "ok"
    else
        log_line "VERIFY: tang did NOT respond on localhost:${port}"
        echo "failed"
    fi
}

feature_tang_server_config() {
    if ! is_pkg_installed tang; then
        warden_msg "Tang not installed" "Tang isn't installed on this host yet. Install it from menu 1 first."
        return 0
    fi

    local port
    port="$(whiptail --inputbox "Port for the Tang server to listen on:" 10 60 "80" 3>&1 1>&2 2>&3)" || return 0
    if ! is_valid_port "$port"; then
        warden_msg "Invalid port" "'${port}' isn't a valid port number (1-65535)."
        return 0
    fi

    if warden_yesno "Preview first?" "Show what would change without actually changing it (dry-run)?"; then
        local saved_dry_run="${WARDEN_DRY_RUN}"
        WARDEN_DRY_RUN=1
        ensure_tangd_port "$port"
        WARDEN_DRY_RUN="$saved_dry_run"
        if ! warden_yesno "Proceed?" "Proceed with the real configuration now?"; then
            return 0
        fi
    fi

    ensure_tangd_port "$port"
    ensure_systemd_unit_enabled "$WARDEN_TANGD_SOCKET_UNIT"
    ensure_systemd_unit_active "$WARDEN_TANGD_SOCKET_UNIT"

    if is_ufw_active; then
        if warden_yesno "ufw is active" "ufw is active on this host. Allow port ${port}/tcp through it?"; then
            ensure_ufw_allows_port "$port"
        fi
    fi

    local verify_result
    verify_result="$(verify_tang_local "$port")"
    if [[ "$verify_result" == "ok" ]]; then
        warden_msg "Tang server configured" "tangd.socket is listening on port ${port} and responded to a local /adv request.\n\nRemember: /var/db/tang/ needs backing up outside this tool. Warden won't do this automatically -- where you back it up to is your call."
    else
        warden_msg "Configuration applied, but verification failed" "tangd.socket was configured for port ${port}, but a local curl to /adv did not succeed. Check 'systemctl status tangd.socket' and the session log."
    fi
}
