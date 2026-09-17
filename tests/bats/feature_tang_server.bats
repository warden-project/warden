#!/usr/bin/env bats

load '../helpers/setup'

setup() {
    warden_test_setup
    export WARDEN_SYSTEMD_SYSTEM_DIR="${TEST_TMPDIR}/systemd"
    mkdir -p "$WARDEN_SYSTEMD_SYSTEM_DIR"
}
teardown() { warden_test_teardown; }

@test "configured_tangd_port defaults to 80 when no drop-in exists" {
    [ "$(configured_tangd_port)" = "80" ]
}

@test "configured_tangd_port reads back a previously written port" {
    mkdir -p "$(_tangd_dropin_dir)"
    printf '[Socket]\nListenStream=\nListenStream=7500\n' > "$(_tangd_dropin_file)"
    [ "$(configured_tangd_port)" = "7500" ]
}

@test "is_valid_port accepts valid ports" {
    is_valid_port 80
    is_valid_port 1
    is_valid_port 65535
}

@test "is_valid_port rejects out-of-range and non-numeric input" {
    run is_valid_port 0
    [ "$status" -ne 0 ]
    run is_valid_port 65536
    [ "$status" -ne 0 ]
    run is_valid_port "abc"
    [ "$status" -ne 0 ]
    run is_valid_port ""
    [ "$status" -ne 0 ]
}

@test "ensure_tangd_port in dry-run mode does not write the drop-in file" {
    WARDEN_DRY_RUN=1 ensure_tangd_port 7500
    [ ! -f "$(_tangd_dropin_file)" ]
    grep -q "DRY-RUN" "$WARDEN_LOG_FILE"
}

@test "ensure_tangd_port writes the expected drop-in content" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for systemctl daemon-reload"
    fi
    WARDEN_DRY_RUN=0 ensure_tangd_port 7500
    local file
    file="$(_tangd_dropin_file)"
    [ -f "$file" ]
    grep -qx "ListenStream=7500" "$file"
    grep -qx "ListenStream=" "$file"
}

@test "ensure_tangd_port is idempotent: second call with same port is a no-op" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for systemctl daemon-reload"
    fi
    WARDEN_DRY_RUN=0 ensure_tangd_port 7500
    WARDEN_DRY_RUN=0 ensure_tangd_port 7500
    grep -q "already set to 7500, skipping" "$WARDEN_LOG_FILE"
}

@test "ensure_tangd_port backs up the existing drop-in before changing the port" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for systemctl daemon-reload"
    fi
    WARDEN_DRY_RUN=0 ensure_tangd_port 7500
    WARDEN_DRY_RUN=0 ensure_tangd_port 8080
    local file
    file="$(_tangd_dropin_file)"
    grep -qx "ListenStream=8080" "$file"
    [ "$(find "$WARDEN_BACKUP_DIR" -name 'override.conf.*.bak' | wc -l)" -eq 1 ]
}

@test "is_ufw_active reports false when ufw is not installed" {
    PATH="/nonexistent" run is_ufw_active
    [ "$status" -ne 0 ]
}

@test "is_ufw_active and ufw_allows_port parse a stubbed ufw status" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/ufw" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "status" ]; then
    echo "Status: active"
    echo ""
    echo "To                         Action      From"
    echo "--                         ------      ----"
    echo "7500/tcp                   ALLOW       Anywhere"
fi
EOF
    chmod +x "${TEST_TMPDIR}/bin/ufw"
    PATH="${TEST_TMPDIR}/bin:${PATH}" run is_ufw_active
    [ "$status" -eq 0 ]
    PATH="${TEST_TMPDIR}/bin:${PATH}" run ufw_allows_port 7500
    [ "$status" -eq 0 ]
    PATH="${TEST_TMPDIR}/bin:${PATH}" run ufw_allows_port 9999
    [ "$status" -ne 0 ]
}

@test "ensure_ufw_allows_port skips when the rule already exists" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/ufw" <<'EOF'
#!/usr/bin/env bash
echo "7500/tcp                   ALLOW       Anywhere"
EOF
    chmod +x "${TEST_TMPDIR}/bin/ufw"
    PATH="${TEST_TMPDIR}/bin:${PATH}" ensure_ufw_allows_port 7500
    grep -q "already allowed, skipping" "$WARDEN_LOG_FILE"
}

@test "verify_tang_local reports ok when curl succeeds" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/bin/curl"
    PATH="${TEST_TMPDIR}/bin:${PATH}" run verify_tang_local 7500
    [ "$output" = "ok" ]
}

@test "verify_tang_local reports failed when curl fails" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
    chmod +x "${TEST_TMPDIR}/bin/curl"
    PATH="${TEST_TMPDIR}/bin:${PATH}" run verify_tang_local 7500
    [ "$output" = "failed" ]
}
