#!/usr/bin/env bats

load '../helpers/setup'

setup() { warden_test_setup; }
teardown() { warden_test_teardown; }

@test "run_cmd executes and logs in real mode" {
    local marker="${TEST_TMPDIR}/marker"
    WARDEN_DRY_RUN=0 run_cmd "touch marker" -- touch "$marker"
    [ -f "$marker" ]
    grep -q "RUN touch marker" "$WARDEN_LOG_FILE"
}

@test "run_cmd does not execute in dry-run mode" {
    local marker="${TEST_TMPDIR}/marker"
    WARDEN_DRY_RUN=1 run_cmd "touch marker" -- touch "$marker"
    [ ! -f "$marker" ]
    grep -q "\[DRY-RUN\] touch marker" "$WARDEN_LOG_FILE"
}

@test "run_cmd propagates a non-zero exit status" {
    run env WARDEN_DRY_RUN=0 bash -c "source '${WARDEN_ROOT}/lib/core/log.sh'; source '${WARDEN_ROOT}/lib/core/exec.sh'; WARDEN_LOG_DIR='${WARDEN_LOG_DIR}'; log_init; run_cmd 'fail' -- false"
    [ "$status" -ne 0 ]
}

@test "run_cmd requires a -- separator before the command" {
    run run_cmd "bad call" touch "${TEST_TMPDIR}/marker"
    [ "$status" -eq 2 ]
}
