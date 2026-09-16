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
