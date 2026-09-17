# shellcheck shell=bash
# lib/core/pkg.sh — idempotent package + apt-source checks
#
# The clevis-systemd gap (installed clevis/clevis-luks but not
# clevis-systemd, silently breaking late-boot unlock) is why every
# package this tool depends on is checked explicitly and individually,
# never assumed to ride in with a related package.

is_pkg_installed() {
    local pkg="$1"
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'
}

# ensure_pkg_installed <pkg> — idempotent: no-op if already installed.
ensure_pkg_installed() {
    local pkg="$1"
    if is_pkg_installed "$pkg"; then
        log_line "PKG: ${pkg} already installed, skipping"
        return 0
    fi
    run_cmd "install package ${pkg}" -- apt-get install -y "$pkg"
}

is_universe_enabled() {
    apt-cache policy 2>/dev/null | grep -q 'universe'
}

ensure_universe_enabled() {
    if is_universe_enabled; then
        log_line "PKG: universe archive already enabled"
        return 0
    fi
    run_cmd "enable universe archive" -- add-apt-repository -y universe
    run_cmd "refresh apt package lists" -- apt-get update
}

is_systemd_unit_enabled() {
    local unit="$1"
    systemctl is-enabled --quiet "$unit" 2>/dev/null
}

ensure_systemd_unit_enabled() {
    local unit="$1"
    if is_systemd_unit_enabled "$unit"; then
        log_line "UNIT: ${unit} already enabled, skipping"
        return 0
    fi
    run_cmd "enable ${unit}" -- systemctl enable "$unit"
}

is_systemd_unit_active() {
    local unit="$1"
    systemctl is-active --quiet "$unit" 2>/dev/null
}

ensure_systemd_unit_active() {
    local unit="$1"
    if is_systemd_unit_active "$unit"; then
        log_line "UNIT: ${unit} already active, skipping"
        return 0
    fi
    run_cmd "start ${unit}" -- systemctl start "$unit"
}

# restart_systemd_unit <unit> — unconditional, not idempotency-checked
# like the others: for a unit whose on-disk config just changed while
# it was already running. Confirmed on real hardware that this matters
# for socket units specifically -- systemd logs "Socket unit
# configuration has changed while unit has been running, no open
# socket file descriptor left" after a drop-in change + daemon-reload
# alone, and the unit stays bound to its old config (e.g. the old
# port) until explicitly restarted. "Already active" is exactly the
# broken state here, so the normal ensure_*_active idempotency check
# (skip if already active) is the wrong tool for this case.
restart_systemd_unit() {
    local unit="$1"
    run_cmd "restart ${unit} to apply changed config" -- systemctl restart "$unit"
}

ensure_systemd_unit_disabled() {
    local unit="$1"
    if ! is_systemd_unit_enabled "$unit"; then
        log_line "UNIT: ${unit} already disabled, skipping"
        return 0
    fi
    run_cmd "disable ${unit}" -- systemctl disable "$unit"
}

ensure_systemd_unit_inactive() {
    local unit="$1"
    if ! is_systemd_unit_active "$unit"; then
        log_line "UNIT: ${unit} already inactive, skipping"
        return 0
    fi
    run_cmd "stop ${unit}" -- systemctl stop "$unit"
}

# ensure_pkg_removed <pkg> — idempotent: no-op if already absent.
ensure_pkg_removed() {
    local pkg="$1"
    if ! is_pkg_installed "$pkg"; then
        log_line "PKG: ${pkg} already not installed, skipping"
        return 0
    fi
    run_cmd "remove package ${pkg}" -- apt-get remove -y "$pkg"
}
