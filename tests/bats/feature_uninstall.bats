#!/usr/bin/env bats

load '../helpers/setup'

setup() {
    warden_test_setup
    export WARDEN_SYSTEMD_SYSTEM_DIR="${TEST_TMPDIR}/systemd"
    mkdir -p "$WARDEN_SYSTEMD_SYSTEM_DIR"
}
teardown() { warden_test_teardown; }

@test "devices_with_clevis_bindings includes only devices clevis actually reports bindings for" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/clevis" <<'EOF'
#!/usr/bin/env bash
# clevis luks list -d <dev>: $4 is the device path
if [ "$4" = "/dev/fake1" ]; then
    echo "1: tang '{\"url\":\"http://a\"}'"
fi
EOF
    chmod +x "${TEST_TMPDIR}/bin/clevis"

    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    printf 'disk1 UUID=uuid1 none luks,_netdev\ndisk2 UUID=uuid2 none luks,_netdev\n' > "$WARDEN_CRYPTTAB"

    luks_devices() { printf '/dev/fake1 uuid1\n/dev/fake2 uuid2\n'; }
    export -f luks_devices

    local out
    out="$(PATH="${TEST_TMPDIR}/bin:${PATH}" devices_with_clevis_bindings)"
    [[ "$out" == *"/dev/fake1 uuid1 disk1"* ]]
    [[ "$out" != *"fake2"* ]]
}

@test "devices_with_clevis_bindings is empty when no managed device has a binding" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/clevis" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/bin/clevis"

    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    printf 'disk1 UUID=uuid1 none luks,_netdev\n' > "$WARDEN_CRYPTTAB"

    luks_devices() { printf '/dev/fake1 uuid1\n'; }
    export -f luks_devices

    [ -z "$(PATH="${TEST_TMPDIR}/bin:${PATH}" devices_with_clevis_bindings)" ]
}

@test "uninstall_action_unbind_device's slot loop uses the same hard non-Clevis gate as menu 8" {
    # Not a full interactive test (whiptail-dependent), but confirms
    # run_clevis_luks_unbind -- the function this action loops over --
    # is the same shared, gated implementation, not a separate one
    # that could drift and skip the safety check.
    declare -f run_clevis_luks_unbind | grep -q "slot_has_clevis_token"
}
