#!/usr/bin/env bats

load '../helpers/setup'

setup() { warden_test_setup; }
teardown() { warden_test_teardown; }

@test "backup_file copies the file and preserves the original" {
    local target backup
    target="${TEST_TMPDIR}/crypttab"
    printf 'existing-entry none defaults\n' > "$target"
    backup="$(backup_file "$target")"
    [ -f "$backup" ]
    diff -q "$target" "$backup"
}

@test "append_line_if_missing adds a new line and backs up first" {
    local target
    target="${TEST_TMPDIR}/crypttab"
    printf 'existing-entry none defaults\n' > "$target"
    append_line_if_missing "$target" "new-entry UUID=abc none luks,_netdev"
    grep -qxF "existing-entry none defaults" "$target"
    grep -qxF "new-entry UUID=abc none luks,_netdev" "$target"
    [ "$(find "$WARDEN_BACKUP_DIR" -name 'crypttab.*.bak' | wc -l)" -eq 1 ]
}

@test "append_line_if_missing is idempotent: does not duplicate an existing line" {
    local target
    target="${TEST_TMPDIR}/crypttab"
    printf 'existing-entry none defaults\n' > "$target"
    append_line_if_missing "$target" "existing-entry none defaults"
    [ "$(grep -c '^existing-entry none defaults$' "$target")" -eq 1 ]
}

@test "append_line_if_missing never touches unrelated existing lines" {
    local target
    target="${TEST_TMPDIR}/crypttab"
    printf 'unrelated-a UUID=aaa none defaults\nunrelated-b UUID=bbb none defaults\n' > "$target"
    append_line_if_missing "$target" "new-entry UUID=ccc none luks,_netdev"
    [ "$(sed -n '1p' "$target")" = "unrelated-a UUID=aaa none defaults" ]
    [ "$(sed -n '2p' "$target")" = "unrelated-b UUID=bbb none defaults" ]
}
