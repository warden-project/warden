#!/usr/bin/env bats

load '../helpers/setup'

setup() { warden_test_setup; }
teardown() { warden_test_teardown; }

@test "crypttab_mapper_for_uuid finds the mapper for a matching UUID" {
    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    printf 'data-disk UUID=abc-123 none luks,_netdev\n' > "$WARDEN_CRYPTTAB"
    [ "$(crypttab_mapper_for_uuid abc-123)" = "data-disk" ]
}

@test "crypttab_mapper_for_uuid returns empty for an unmanaged UUID" {
    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    printf 'data-disk UUID=abc-123 none luks,_netdev\n' > "$WARDEN_CRYPTTAB"
    [ -z "$(crypttab_mapper_for_uuid xyz-999)" ]
}

@test "crypttab_mapper_for_uuid ignores commented-out lines" {
    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    printf '#data-disk UUID=abc-123 none luks,_netdev\n' > "$WARDEN_CRYPTTAB"
    [ -z "$(crypttab_mapper_for_uuid abc-123)" ]
}

@test "fstab_has_mapper detects a present entry" {
    WARDEN_FSTAB="${TEST_TMPDIR}/fstab"
    printf '/dev/mapper/data-disk /mnt/data ext4 defaults,nofail 0 2\n' > "$WARDEN_FSTAB"
    fstab_has_mapper data-disk
}

@test "fstab_has_mapper reports missing entry" {
    WARDEN_FSTAB="${TEST_TMPDIR}/fstab"
    printf '/dev/mapper/other-disk /mnt/other ext4 defaults,nofail 0 2\n' > "$WARDEN_FSTAB"
    run fstab_has_mapper data-disk
    [ "$status" -ne 0 ]
}

@test "crypttab_mapper_names lists every mapper name" {
    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    printf 'data-disk UUID=abc-123 none luks,_netdev\nbackup-disk UUID=def-456 none luks,_netdev\n' > "$WARDEN_CRYPTTAB"
    local out
    out="$(crypttab_mapper_names)"
    echo "$out" | grep -qx "data-disk"
    echo "$out" | grep -qx "backup-disk"
}

@test "crypttab_mapper_names ignores commented-out lines" {
    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    printf '#data-disk UUID=abc-123 none luks,_netdev\n' > "$WARDEN_CRYPTTAB"
    [ -z "$(crypttab_mapper_names)" ]
}

@test "luks_devices lists a throwaway loop-backed LUKS device" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for losetup/cryptsetup"
    fi
    local img loopdev
    img="${TEST_TMPDIR}/disk.img"
    truncate -s 64M "$img"
    loopdev="$(losetup -f --show "$img")"
    warden_test_luks_format "$loopdev" "testpassphrase"
    run luks_devices
    [[ "$output" == *"$loopdev"* ]]
    losetup -d "$loopdev"
}

@test "managed_luks_devices excludes an unmanaged loop-backed LUKS device" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for losetup/cryptsetup"
    fi
    local img loopdev
    img="${TEST_TMPDIR}/disk.img"
    truncate -s 64M "$img"
    loopdev="$(losetup -f --show "$img")"
    warden_test_luks_format "$loopdev" "testpassphrase"
    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    : > "$WARDEN_CRYPTTAB"
    run managed_luks_devices
    [[ "$output" != *"$loopdev"* ]]
    losetup -d "$loopdev"
}

@test "managed_luks_devices includes a device once it has a crypttab entry" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for losetup/cryptsetup"
    fi
    local img loopdev uuid
    img="${TEST_TMPDIR}/disk.img"
    truncate -s 64M "$img"
    loopdev="$(losetup -f --show "$img")"
    warden_test_luks_format "$loopdev" "testpassphrase"
    uuid="$(uuid_for_device "$loopdev")"
    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    printf 'data-disk UUID=%s none luks,_netdev\n' "$uuid" > "$WARDEN_CRYPTTAB"
    run managed_luks_devices
    [[ "$output" == *"$loopdev"*"data-disk"* ]]
    losetup -d "$loopdev"
}

@test "managed_luks_devices excludes the current root device even with a matching crypttab entry" {
    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    local root_src
    root_src="$(findmnt -no SOURCE /)"
    printf 'fake-root UUID=test-fake-uuid none luks,_netdev\n' > "$WARDEN_CRYPTTAB"
    # Override luks_devices for this test only, to exercise the guard
    # against the real root device without needing root to actually
    # LUKS-format anything.
    luks_devices() { printf '%s %s\n' "$root_src" "test-fake-uuid"; }
    run managed_luks_devices
    [[ "$output" != *"$root_src"* ]]
}
