#!/usr/bin/env bats

load '../helpers/setup'

setup() {
    warden_test_setup
    export WARDEN_HEADER_BACKUP_DIR="${TEST_TMPDIR}/luks-headers"
}
teardown() { warden_test_teardown; }

@test "existing_header_backups reports none when nothing has been backed up" {
    [ -z "$(existing_header_backups "some-uuid")" ]
}

@test "existing_header_backups finds a previously written backup for the same uuid" {
    mkdir -p "$WARDEN_HEADER_BACKUP_DIR"
    touch "${WARDEN_HEADER_BACKUP_DIR}/abc-123.20260101T000000Z.header"
    local out
    out="$(existing_header_backups "abc-123")"
    [[ "$out" == *"abc-123.20260101T000000Z.header"* ]]
}

@test "existing_header_backups does not match a different uuid's backup" {
    mkdir -p "$WARDEN_HEADER_BACKUP_DIR"
    touch "${WARDEN_HEADER_BACKUP_DIR}/other-uuid.20260101T000000Z.header"
    [ -z "$(existing_header_backups "abc-123")" ]
}

@test "backup_luks_header in dry-run mode does not create a file" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/cryptsetup" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/bin/cryptsetup"
    WARDEN_DRY_RUN=1 PATH="${TEST_TMPDIR}/bin:${PATH}" backup_luks_header "/dev/fake" "abc-123" >/dev/null
    [ -z "$(existing_header_backups "abc-123")" ]
}

@test "backup_luks_header writes a mode-600 file named after the uuid and timestamp" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/cryptsetup" <<'EOF'
#!/usr/bin/env bash
# emulate luksHeaderBackup: find the --header-backup-file argument and create it
prev=""
for arg in "$@"; do
    if [ "$prev" = "--header-backup-file" ]; then
        touch "$arg"
    fi
    prev="$arg"
done
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/bin/cryptsetup"
    local dest
    dest="$(WARDEN_DRY_RUN=0 PATH="${TEST_TMPDIR}/bin:${PATH}" backup_luks_header "/dev/fake" "abc-123")"
    [[ "$dest" == "${WARDEN_HEADER_BACKUP_DIR}/abc-123."*".header" ]]
    [ -f "$dest" ]
    [ "$(stat -c '%a' "$dest")" = "600" ]
}

@test "backup_luks_header propagates a cryptsetup failure" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/cryptsetup" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${TEST_TMPDIR}/bin/cryptsetup"
    run env WARDEN_DRY_RUN=0 PATH="${TEST_TMPDIR}/bin:${PATH}" bash -c "
        source '${WARDEN_ROOT}/lib/core/log.sh'
        source '${WARDEN_ROOT}/lib/core/exec.sh'
        WARDEN_LOG_DIR='${WARDEN_LOG_DIR}'
        WARDEN_HEADER_BACKUP_DIR='${WARDEN_HEADER_BACKUP_DIR}'
        log_init
        source '${WARDEN_ROOT}/lib/features/header_backup.sh'
        backup_luks_header /dev/fake abc-123
    "
    [ "$status" -ne 0 ]
}
