#!/usr/bin/env bats

load '../helpers/setup'

setup() { warden_test_setup; }
teardown() { warden_test_teardown; }

@test "describe_lateboot_status reports installed and the unit's enabled/state lines" {
    local out
    out="$(describe_lateboot_status)"
    [[ "$out" == *"clevis-systemd: installed"* ]]
    [[ "$out" == *"${WARDEN_ASKPASS_PATH_UNIT} enabled:"* ]]
    [[ "$out" == *"${WARDEN_ASKPASS_PATH_UNIT} state:"* ]]
}

@test "describe_lateboot_status reports 'not present' for a unit that doesn't exist on this system" {
    local out
    out="$(describe_lateboot_status)"
    [[ "$out" == *"state: not present"* ]]
}
