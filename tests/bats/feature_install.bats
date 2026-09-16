#!/usr/bin/env bats

load '../helpers/setup'

setup() { warden_test_setup; }
teardown() { warden_test_teardown; }

@test "install_selected in dry-run mode does not actually install anything" {
    if is_pkg_installed tang; then
        skip "tang is already installed on this machine, dry-run-vs-real can't be distinguished"
    fi
    WARDEN_DRY_RUN=1 install_selected tang 0
    run is_pkg_installed tang
    [ "$status" -ne 0 ]
    grep -q "DRY-RUN" "$WARDEN_LOG_FILE"
}

@test "install_selected skips already-installed packages (idempotent)" {
    WARDEN_DRY_RUN=1 install_selected tang 0
    grep -q "install package tang" "$WARDEN_LOG_FILE" || grep -q "already installed" "$WARDEN_LOG_FILE"
}

@test "install_selected only requests tpm2 when explicitly asked" {
    WARDEN_DRY_RUN=1 install_selected clevis 0
    run grep -q "clevis-tpm2" "$WARDEN_LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "install_selected requests tpm2 when asked" {
    WARDEN_DRY_RUN=1 install_selected clevis 1
    grep -q "clevis-tpm2" "$WARDEN_LOG_FILE"
}
