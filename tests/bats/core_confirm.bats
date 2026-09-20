#!/usr/bin/env bats

load '../helpers/setup'

setup() { warden_test_setup; }
teardown() { warden_test_teardown; }

@test "confirm_typed_phrase succeeds on an exact match" {
    run bash -c "echo 'ERASE a1b2c3d4' | { source '${WARDEN_ROOT}/lib/core/log.sh'; source '${WARDEN_ROOT}/lib/core/confirm.sh'; WARDEN_LOG_DIR='${WARDEN_LOG_DIR}'; WARDEN_NO_WHIPTAIL=1; log_init; confirm_typed_phrase 'ERASE a1b2c3d4' 'type it'; }"
    [ "$status" -eq 0 ]
}

@test "confirm_typed_phrase fails on a mismatch" {
    run bash -c "echo 'nope' | { source '${WARDEN_ROOT}/lib/core/log.sh'; source '${WARDEN_ROOT}/lib/core/confirm.sh'; WARDEN_LOG_DIR='${WARDEN_LOG_DIR}'; WARDEN_NO_WHIPTAIL=1; log_init; confirm_typed_phrase 'ERASE a1b2c3d4' 'type it'; }"
    [ "$status" -eq 1 ]
}

@test "confirm_typed_phrase fails on a near-miss (case/whitespace)" {
    run bash -c "echo 'erase a1b2c3d4 ' | { source '${WARDEN_ROOT}/lib/core/log.sh'; source '${WARDEN_ROOT}/lib/core/confirm.sh'; WARDEN_LOG_DIR='${WARDEN_LOG_DIR}'; WARDEN_NO_WHIPTAIL=1; log_init; confirm_typed_phrase 'ERASE a1b2c3d4' 'type it'; }"
    [ "$status" -eq 1 ]
}

@test "uuid_fragment takes the first 8 characters" {
    [ "$(uuid_fragment "3f2a1c9e-88b4-4a91-9c2d-77e0a1b4f9aa")" = "3f2a1c9e" ]
}

@test "uuid_fragment handles a short input without erroring" {
    [ "$(uuid_fragment "abc")" = "abc" ]
}

@test "confirm_destructive_device_action's own whiptail calls are Escape-safe, as defense in depth" {
    # Both real call sites (danger_erase.sh, luks_setup.sh) invoke this
    # as `if ! confirm_destructive_device_action ...; then`, which
    # empirically suspends set -e for everything inside the call
    # (verified directly: a failing command deep inside a function
    # called as an `if` condition does not trigger errexit, even
    # transitively) -- so this isn't currently reachable as a live
    # crash via either existing caller. Guarded anyway: this is a
    # shared safety-critical primitive, and a future bare (non-`if`)
    # caller would otherwise silently inherit an Escape-crash bug.
    local body
    body="$(declare -f confirm_destructive_device_action)"
    [[ "$body" == *'--textbox "$snapshot_file" 24 100 || true'* ]]
    [[ "$body" == *'Warden refuses this by default." 14 78 || true'* ]]
}
