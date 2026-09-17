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
