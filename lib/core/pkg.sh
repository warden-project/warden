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
