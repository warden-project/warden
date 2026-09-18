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
    # Must override WARDEN_ASKPASS_PATH_UNIT to a name guaranteed not to
    # exist: on a real host with clevis-systemd actually installed (as
    # on real hardware used for testing), the default
    # clevis-luks-askpass.path genuinely exists, which would make this
    # assertion fail for reasons unrelated to what the test checks.
    WARDEN_ASKPASS_PATH_UNIT="definitely-not-a-real-unit.path"
    local out
    out="$(describe_lateboot_status)"
    [[ "$out" == *"state: not present"* ]]
}
