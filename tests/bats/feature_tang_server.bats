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

@test "is_port_in_use is false for a port nothing is listening on" {
    run is_port_in_use 18732
    [ "$status" -ne 0 ]
}

@test "is_port_in_use is true for a port something is actually listening on" {
    python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 18733))
s.listen(1)
time.sleep(5)
" &
    local pid=$!
    sleep 1
    is_port_in_use 18733
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
}

@test "describe_port_listener names the actual listening process" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root to see process names via ss -p"
    fi
    python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 18734))
s.listen(1)
time.sleep(5)
" &
    local pid=$!
    sleep 1
    local listener
    listener="$(describe_port_listener 18734)"
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    [[ "$listener" == *"python3"* ]]
}

@test "describe_port_listener is empty when nothing is listening" {
    [ -z "$(describe_port_listener 18735)" ]
}

@test "feature_tang_server_config warns about a port collision with something other than tangd's own listener" {
    # Found via a real user question, not a real-hardware bug: setting
    # a new Tang port previously had no check for whether something
    # else was already using it -- is_valid_port only validates the
    # number is in range. Not a full interactive test (whiptail-
    # dependent); confirms the check is wired in.
    local body
    body="$(declare -f feature_tang_server_config)"
    [[ "$body" == *"is_port_in_use"* ]]
    [[ "$body" == *"Port already in use"* ]]
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

@test "describe_tang_server_status reports the configured port" {
    mkdir -p "$(_tangd_dropin_dir)"
    printf '[Socket]\nListenStream=\nListenStream=7500\n' > "$(_tangd_dropin_file)"
    local out
    out="$(describe_tang_server_status)"
    [[ "$out" == *"Configured port: 7500"* ]]
}

@test "describe_tang_server_status reports ufw as not active without a usable ufw" {
    # On this machine ufw exists but refuses to run unprivileged, which
    # is_ufw_active already treats as "not active" -- no need to hide
    # the binary, and doing so via PATH would break every other tool
    # (mktemp, systemctl, ...) this function's callees also need.
    local out
    out="$(describe_tang_server_status)"
    [[ "$out" == *"ufw: not active"* ]]
}

@test "describe_tang_server_status shows the ufw rule state when ufw is active" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/ufw" <<'EOF'
#!/usr/bin/env bash
echo "Status: active"
echo "7500/tcp                   ALLOW       Anywhere"
EOF
    chmod +x "${TEST_TMPDIR}/bin/ufw"
    mkdir -p "$(_tangd_dropin_dir)"
    printf '[Socket]\nListenStream=\nListenStream=7500\n' > "$(_tangd_dropin_file)"
    local out
    out="$(PATH="${TEST_TMPDIR}/bin:${PATH}" describe_tang_server_status)"
    [[ "$out" == *"ufw: active, port 7500 allowed: yes"* ]]
}
