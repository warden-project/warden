#!/usr/bin/env bats

load '../helpers/setup'

setup() { warden_test_setup; }
teardown() { warden_test_teardown; }

@test "is_system_critical flags the current root device" {
    local root_src
    root_src="$(findmnt -no SOURCE /)"
    is_system_critical "$root_src"
}

@test "guard_not_system_critical refuses the current root device" {
    local root_src
    root_src="$(findmnt -no SOURCE /)"
    run guard_not_system_critical "$root_src"
    [ "$status" -eq 1 ]
}

@test "is_system_critical does not flag a throwaway loop-backed LUKS device" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for losetup/cryptsetup"
    fi
    local img loopdev
    img="${TEST_TMPDIR}/disk.img"
    truncate -s 64M "$img"
    loopdev="$(losetup -f --show "$img")"
    warden_test_luks_format "$loopdev" "testpassphrase"
    run is_system_critical "$loopdev"
    [ "$status" -eq 1 ]
    losetup -d "$loopdev"
}
