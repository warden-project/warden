#!/usr/bin/env bats

load '../helpers/setup'

setup() { warden_test_setup; }
teardown() { warden_test_teardown; }

@test "log_init creates a session log file" {
    [ -n "$WARDEN_LOG_FILE" ]
    [ -f "$WARDEN_LOG_FILE" ]
}

@test "log_line appends timestamped content" {
    log_line "hello world"
    grep -q "hello world" "$WARDEN_LOG_FILE"
}

@test "log_diff records a unified diff between two files" {
    local before after
    before="$(mktemp)"; after="$(mktemp)"
    printf 'a\nb\nc\n' > "$before"
    printf 'a\nB\nc\n' > "$after"
    log_diff "test-file" "$before" "$after"
    grep -q -- '-b' "$WARDEN_LOG_FILE"
    grep -q -- '+B' "$WARDEN_LOG_FILE"
    rm -f "$before" "$after"
}
