#!/usr/bin/env bats

load '../helpers/setup'

setup() { warden_test_setup; }
teardown() { warden_test_teardown; }

# --- health_check_tang -------------------------------------------------

@test "health_check_tang reports no bindings configured when none exist" {
    run health_check_tang ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"no Tang bindings configured"* ]]
}

@test "health_check_tang passes for a reachable server" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "0.02"
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/bin/curl"
    local pins_text='2: tang '"'"'{"url":"http://127.0.0.1:9"}'"'"''
    PATH="${TEST_TMPDIR}/bin:${PATH}" run health_check_tang "$pins_text"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS Tang http://127.0.0.1:9: reachable 20ms"* ]]
}

@test "health_check_tang fails for an unreachable server" {
    local pins_text='2: tang '"'"'{"url":"http://127.0.0.1:1"}'"'"''
    run health_check_tang "$pins_text"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL Tang http://127.0.0.1:1: unreachable"* ]]
}

@test "health_check_tang finds a tang URL nested inside an sss config" {
    local pins_text='3: sss '"'"'{"t":1,"pins":{"tang":[{"url":"http://127.0.0.1:1"}],"tpm2":[{}]}}'"'"''
    run health_check_tang "$pins_text"
    [ "$status" -eq 1 ]
    [[ "$output" == *"http://127.0.0.1:1"* ]]
}

# --- health_check_tpm2 --------------------------------------------------

@test "health_check_tpm2 reports no TPM2 bindings configured when none exist" {
    run health_check_tpm2 "2: tang '{\"url\":\"http://example.com\"}'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no TPM2 bindings configured"* ]]
}

@test "health_check_tpm2 passes when hardware and package are both present" {
    is_tpm2_present() { return 0; }
    export -f is_tpm2_present
    is_pkg_installed() { [[ "$1" == "clevis-tpm2" ]]; }
    export -f is_pkg_installed
    run health_check_tpm2 "2: tpm2 '{}'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS TPM2"* ]]
}

@test "health_check_tpm2 fails when the TPM2 device node is missing" {
    is_tpm2_present() { return 1; }
    export -f is_tpm2_present
    run health_check_tpm2 "2: tpm2 '{}'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL TPM2"* ]]
    [[ "$output" == *"no TPM2 device node"* ]]
}

@test "health_check_tpm2 fails when clevis-tpm2 is not installed" {
    is_tpm2_present() { return 0; }
    export -f is_tpm2_present
    is_pkg_installed() { return 1; }
    export -f is_pkg_installed
    run health_check_tpm2 "2: tpm2 '{}'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"clevis-tpm2 package is not installed"* ]]
}

@test "health_check_tpm2 also detects a tpm2 pin nested inside an sss config" {
    is_tpm2_present() { return 0; }
    export -f is_tpm2_present
    is_pkg_installed() { [[ "$1" == "clevis-tpm2" ]]; }
    export -f is_pkg_installed
    run health_check_tpm2 '3: sss '"'"'{"t":1,"pins":{"tpm2":[{}]}}'"'"''
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS TPM2"* ]]
}

# --- health_check_zfs ----------------------------------------------------

@test "health_check_zfs reports none configured when no device is a ZFS member" {
    managed_luks_devices() { printf '/dev/fake1 uuid1 disk1\n'; }
    export -f managed_luks_devices
    is_zfs_pool_member() { return 1; }
    export -f is_zfs_pool_member
    run health_check_zfs
    [ "$status" -eq 0 ]
    [[ "$output" == *"no ZFS-backed devices configured"* ]]
}

@test "health_check_zfs passes when the import unit is enabled and active" {
    managed_luks_devices() { printf '/dev/fake1 uuid1 disk1\n'; }
    export -f managed_luks_devices
    is_zfs_pool_member() { return 0; }
    export -f is_zfs_pool_member
    is_systemd_unit_enabled() { return 0; }
    export -f is_systemd_unit_enabled
    is_systemd_unit_active() { return 0; }
    export -f is_systemd_unit_active
    run health_check_zfs
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS ZFS disk1"* ]]
}

@test "health_check_zfs fails when the import unit is not active" {
    managed_luks_devices() { printf '/dev/fake1 uuid1 disk1\n'; }
    export -f managed_luks_devices
    is_zfs_pool_member() { return 0; }
    export -f is_zfs_pool_member
    is_systemd_unit_enabled() { return 0; }
    export -f is_systemd_unit_enabled
    is_systemd_unit_active() { return 1; }
    export -f is_systemd_unit_active
    run health_check_zfs
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL ZFS disk1"* ]]
}

# --- health_check_late_boot -----------------------------------------------

@test "health_check_late_boot reports clevis-systemd not installed" {
    is_pkg_installed() { return 1; }
    export -f is_pkg_installed
    run health_check_late_boot
    [ "$status" -eq 0 ]
    [[ "$output" == *"clevis-systemd not installed"* ]]
}

@test "health_check_late_boot passes when the askpass path unit is active" {
    is_pkg_installed() { return 0; }
    export -f is_pkg_installed
    is_systemd_unit_active() { return 0; }
    export -f is_systemd_unit_active
    run health_check_late_boot
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS Late-boot unlocker"* ]]
}

@test "health_check_late_boot fails when the askpass path unit is not active" {
    is_pkg_installed() { return 0; }
    export -f is_pkg_installed
    is_systemd_unit_active() { return 1; }
    export -f is_systemd_unit_active
    run health_check_late_boot
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL Late-boot unlocker"* ]]
}

# --- health_check_root_drift ----------------------------------------------

@test "health_check_root_drift reports not enabled when root-unlock isn't in use" {
    is_root_unlock_enabled() { return 1; }
    export -f is_root_unlock_enabled
    run health_check_root_drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"Root-drive unlock: (not enabled)"* ]]
}

@test "health_check_root_drift passes when there is no drift" {
    is_root_unlock_enabled() { return 0; }
    export -f is_root_unlock_enabled
    root_unlock_initramfs_drift_status() { echo "Current initramfs matches the last recorded state -- no drift detected."; }
    export -f root_unlock_initramfs_drift_status
    run health_check_root_drift
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS Root-drive unlock"* ]]
}

@test "health_check_root_drift warns (not fails silently) when drift is detected" {
    is_root_unlock_enabled() { return 0; }
    export -f is_root_unlock_enabled
    root_unlock_initramfs_drift_status() { echo "DRIFT DETECTED: something changed."; }
    export -f root_unlock_initramfs_drift_status
    run health_check_root_drift
    [ "$status" -eq 1 ]
    [[ "$output" == *"WARN Root-drive unlock"* ]]
    [[ "$output" == *"run Snapshot"* ]]
}

# --- render_health_check_report -------------------------------------------

@test "render_health_check_report is OK overall when every check passes" {
    all_configured_pins_text() { :; }
    export -f all_configured_pins_text
    health_check_tang() { echo "PASS Tang"; return 0; }
    export -f health_check_tang
    health_check_tpm2() { echo "TPM2: none"; return 0; }
    export -f health_check_tpm2
    health_check_zfs() { echo "ZFS: none"; return 0; }
    export -f health_check_zfs
    health_check_late_boot() { echo "Late-boot: none"; return 0; }
    export -f health_check_late_boot
    health_check_root_drift() { echo "Root: none"; return 0; }
    export -f health_check_root_drift

    run render_health_check_report
    [ "$status" -eq 0 ]
    [[ "$output" == *"Overall: OK -- nothing needs attention."* ]]
}

@test "render_health_check_report needs attention overall when any single check fails" {
    all_configured_pins_text() { :; }
    export -f all_configured_pins_text
    health_check_tang() { echo "PASS Tang"; return 0; }
    export -f health_check_tang
    health_check_tpm2() { echo "FAIL TPM2: no hardware"; return 1; }
    export -f health_check_tpm2
    health_check_zfs() { echo "ZFS: none"; return 0; }
    export -f health_check_zfs
    health_check_late_boot() { echo "Late-boot: none"; return 0; }
    export -f health_check_late_boot
    health_check_root_drift() { echo "Root: none"; return 0; }
    export -f health_check_root_drift

    run render_health_check_report
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL TPM2"* ]]
    [[ "$output" == *"one or more checks above need attention"* ]]
}

# --- menu wiring -----------------------------------------------------------

@test "feature_health_check_menu shows render_health_check_report's output and is Escape-safe" {
    local body
    body="$(declare -f feature_health_check_menu)"
    [[ "$body" == *"render_health_check_report"* ]]
    [[ "$body" == *"--textbox"*"|| true"* ]]
}
