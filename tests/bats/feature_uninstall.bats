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

@test "uninstall_action_forget_device's crypttab/fstab patterns remove only the exact mapper's line" {
    # Regression test for a real gap found during real-hardware
    # testing: after a Danger Zone erase (menu 11), a device's
    # crypttab entry has no working unlock method left (all keyslots
    # destroyed) and no "nofail" option, so it can hang the next boot.
    # There was no menu action anywhere to remove that entry. This
    # tests the exact regex patterns uninstall_action_forget_device
    # builds -- not the full interactive flow (whiptail-dependent, not
    # exercised elsewhere in this file either) -- confirming a mapper
    # name that is a prefix of another (e.g. "disk1" vs "disk10") is
    # not over-matched.
    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    WARDEN_FSTAB="${TEST_TMPDIR}/fstab"
    printf 'disk1 UUID=uuid1 none luks,_netdev\ndisk10 UUID=uuid10 none luks,_netdev\n' > "$WARDEN_CRYPTTAB"
    printf '/dev/mapper/disk1 /mnt/disk1 ext4 defaults,nofail 0 2\n/dev/mapper/disk10 /mnt/disk10 ext4 defaults,nofail 0 2\n' > "$WARDEN_FSTAB"

    local mapper="disk1"
    remove_lines_matching "$WARDEN_CRYPTTAB" "^${mapper}[[:space:]]"
    remove_lines_matching "$WARDEN_FSTAB" "/dev/mapper/${mapper}([[:space:]]|\$)"

    ! grep -q '^disk1[[:space:]]' "$WARDEN_CRYPTTAB"
    grep -qxF "disk10 UUID=uuid10 none luks,_netdev" "$WARDEN_CRYPTTAB"
    ! grep -q '/dev/mapper/disk1[[:space:]]' "$WARDEN_FSTAB"
    grep -qxF "/dev/mapper/disk10 /mnt/disk10 ext4 defaults,nofail 0 2" "$WARDEN_FSTAB"
}

@test "uninstall_action_unbind_device's slot loop uses the same hard non-Clevis gate as menu 8" {
    # Not a full interactive test (whiptail-dependent), but confirms
    # run_clevis_luks_unbind -- the function this action loops over --
    # is the same shared, gated implementation, not a separate one
    # that could drift and skip the safety check.
    declare -f run_clevis_luks_unbind | grep -q "slot_has_clevis_token"
}

@test "uninstall_action_forget_device checks for and disables a ZFS import unit" {
    # Not a full interactive test (whiptail-dependent, same as above);
    # confirms the wiring exists for the gap found via real-hardware
    # testing: "forget" only ever removed crypttab/fstab entries, which
    # would leave a ZFS-backed device's warden-zfs-import@ unit enabled
    # and pointing at a device Warden no longer tracks.
    local body
    body="$(declare -f uninstall_action_forget_device)"
    [[ "$body" == *'is_systemd_unit_enabled "warden-zfs-import@'* ]]
    [[ "$body" == *'disable_zfs_import_unit'* ]]
    [[ "$body" == *'zpool export'* ]]
}
