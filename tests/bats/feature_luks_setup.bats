#!/usr/bin/env bats

load '../helpers/setup'

setup() {
    warden_test_setup
    export WARDEN_STATE_DIR="${TEST_TMPDIR}/warden-state"
    export WARDEN_BINDINGS_FILE="${WARDEN_STATE_DIR}/tang-bindings.json"
}
teardown() { warden_test_teardown; }

@test "generate_passphrase produces a reasonably long, non-empty value" {
    local pw
    pw="$(generate_passphrase)"
    [ -n "$pw" ]
    [ "${#pw}" -ge 20 ]
}

@test "generate_passphrase does not repeat itself across calls" {
    local a b
    a="$(generate_passphrase)"
    b="$(generate_passphrase)"
    [ "$a" != "$b" ]
}

@test "format_luks_device in dry-run mode does not touch the device" {
    local img
    img="${TEST_TMPDIR}/disk.img"
    truncate -s 64M "$img"
    local before after
    before="$(md5sum "$img" | cut -d' ' -f1)"
    WARDEN_DRY_RUN=1 format_luks_device "$img" "some-passphrase"
    after="$(md5sum "$img" | cut -d' ' -f1)"
    [ "$before" = "$after" ]
    grep -q "DRY-RUN" "$WARDEN_LOG_FILE"
}

@test "format_luks_device never logs the passphrase value" {
    local img
    img="${TEST_TMPDIR}/disk.img"
    truncate -s 64M "$img"
    WARDEN_DRY_RUN=1 format_luks_device "$img" "super-secret-passphrase-xyz"
    run grep -q "super-secret-passphrase-xyz" "$WARDEN_LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "format_luks_device and create_filesystem work end to end on a loop device" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for losetup/cryptsetup"
    fi
    local img loopdev
    img="${TEST_TMPDIR}/disk.img"
    truncate -s 64M "$img"
    loopdev="$(losetup -f --show "$img")"

    WARDEN_DRY_RUN=0 format_luks_device "$loopdev" "test-passphrase-123"
    run lsblk -no FSTYPE "$loopdev"
    [[ "$output" == "crypto_LUKS" ]]

    WARDEN_DRY_RUN=0 create_filesystem "$loopdev" "test-passphrase-123" "ext4"
    [ ! -e "/dev/mapper/warden-setup-$$" ]

    losetup -d "$loopdev"
}

@test "candidate_format_devices excludes an already-LUKS-formatted device" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for losetup/cryptsetup"
    fi
    local img loopdev
    img="${TEST_TMPDIR}/disk.img"
    truncate -s 64M "$img"
    loopdev="$(losetup -f --show "$img")"
    run candidate_format_devices
    [[ "$output" == *"$loopdev"* ]]

    echo -n "pw" | cryptsetup luksFormat --batch-mode "$loopdev" -
    run candidate_format_devices
    [[ "$output" != *"$loopdev"* ]]

    losetup -d "$loopdev"
}
