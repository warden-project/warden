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

@test "run_cmd always redirects the command's stdin from /dev/null, even when run_cmd itself has a live stdin" {
    # Regression test for a real hang found live: bin/warden normally
    # runs attached to a live interactive terminal (whiptail needs
    # one), and without this, any subprocess run_cmd invokes inherits
    # that same live terminal as its own stdin. `clevis luks unbind`
    # for a tang-pinned slot hung indefinitely this way -- something in
    # its call chain attempts a stdin read that blocks forever waiting
    # for a keypress nobody will ever type, but returns instantly with
    # a harmless notice when stdin is already closed/EOF, as it always
    # should be for a command Warden runs on its own behalf. Uses `cat`
    # as a stand-in for whatever in the real toolchain reads stdin: if
    # run_cmd's own stdin leaked through, cat would echo it back.
    run bash -c "
echo 'this must never reach cat' | {
    source '${WARDEN_ROOT}/lib/core/log.sh'
    source '${WARDEN_ROOT}/lib/core/exec.sh'
    WARDEN_LOG_DIR='${WARDEN_LOG_DIR}'
    log_init
    run_cmd 'cat' -- cat
}
"
    [ "$status" -eq 0 ]
    [[ "$output" != *"this must never reach cat"* ]]
}
