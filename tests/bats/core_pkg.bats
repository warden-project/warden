#!/usr/bin/env bats

load '../helpers/setup'

setup() { warden_test_setup; }
teardown() { warden_test_teardown; }

@test "is_pkg_installed returns true for a known-installed package" {
    is_pkg_installed "coreutils"
}

@test "is_pkg_installed returns false for a bogus package name" {
    run is_pkg_installed "definitely-not-a-real-package-xyz"
    [ "$status" -ne 0 ]
}

@test "ensure_pkg_installed is a no-op when already installed" {
    WARDEN_DRY_RUN=1 run ensure_pkg_installed "coreutils"
    [ "$status" -eq 0 ]
    grep -q "already installed, skipping" "$WARDEN_LOG_FILE"
}

@test "ensure_pkg_removed is a no-op when already absent" {
    WARDEN_DRY_RUN=1 run ensure_pkg_removed "definitely-not-a-real-package-xyz"
    [ "$status" -eq 0 ]
    grep -q "already not installed, skipping" "$WARDEN_LOG_FILE"
}

@test "ensure_pkg_removed requests removal when installed" {
    WARDEN_DRY_RUN=1 ensure_pkg_removed "coreutils"
    grep -q "remove package coreutils" "$WARDEN_LOG_FILE"
}

@test "ensure_systemd_unit_disabled is a no-op for a unit that doesn't exist (already disabled)" {
    WARDEN_DRY_RUN=1 run ensure_systemd_unit_disabled "definitely-not-a-real-unit.service"
    [ "$status" -eq 0 ]
    grep -q "already disabled, skipping" "$WARDEN_LOG_FILE"
}

@test "ensure_systemd_unit_inactive is a no-op for a unit that doesn't exist (already inactive)" {
    WARDEN_DRY_RUN=1 run ensure_systemd_unit_inactive "definitely-not-a-real-unit.service"
    [ "$status" -eq 0 ]
    grep -q "already inactive, skipping" "$WARDEN_LOG_FILE"
}

@test "ensure_systemd_unit_disabled requests disable for a known-enabled unit" {
    if ! systemctl list-unit-files ssh.service --no-legend 2>/dev/null | grep -q .; then
        skip "ssh.service not present on this machine"
    fi
    if ! is_systemd_unit_enabled ssh.service; then
        skip "ssh.service not enabled on this machine"
    fi
    WARDEN_DRY_RUN=1 ensure_systemd_unit_disabled ssh.service
    grep -q "disable ssh.service" "$WARDEN_LOG_FILE"
}
