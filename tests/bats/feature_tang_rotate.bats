#!/usr/bin/env bats

load '../helpers/setup'

setup() {
    warden_test_setup
    export WARDEN_TANG_DB_DIR="${TEST_TMPDIR}/tang-db"
    mkdir -p "$WARDEN_TANG_DB_DIR"
}
teardown() { warden_test_teardown; }

@test "locate_tangd_rotate_keys finds a script among the candidate paths" {
    mkdir -p "${TEST_TMPDIR}/opt"
    cat > "${TEST_TMPDIR}/opt/tangd-rotate-keys" <<'EOF'
#!/usr/bin/env bash
EOF
    chmod +x "${TEST_TMPDIR}/opt/tangd-rotate-keys"
    WARDEN_TANGD_ROTATE_KEYS_CANDIDATES="/does/not/exist ${TEST_TMPDIR}/opt/tangd-rotate-keys"
    [ "$(locate_tangd_rotate_keys)" = "${TEST_TMPDIR}/opt/tangd-rotate-keys" ]
}

@test "locate_tangd_rotate_keys falls back to PATH lookup" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/tangd-rotate-keys" <<'EOF'
#!/usr/bin/env bash
EOF
    chmod +x "${TEST_TMPDIR}/bin/tangd-rotate-keys"
    local out
    out="$(PATH="${TEST_TMPDIR}/bin:${PATH}" locate_tangd_rotate_keys)"
    [ "$out" = "${TEST_TMPDIR}/bin/tangd-rotate-keys" ]
}

@test "locate_tangd_rotate_keys returns nothing when not found anywhere" {
    WARDEN_TANGD_ROTATE_KEYS_CANDIDATES="/does/not/exist" run bash -c "source '${WARDEN_ROOT}/lib/features/tang_rotate.sh'; locate_tangd_rotate_keys"
    [ -z "$output" ]
}

@test "list_tang_keys distinguishes visible and hidden key files" {
    touch "${WARDEN_TANG_DB_DIR}/abc.jwk"
    touch "${WARDEN_TANG_DB_DIR}/.def.jwk"
    local out
    out="$(list_tang_keys)"
    [[ "$out" == *"abc.jwk (visible/advertised)"* ]]
    [[ "$out" == *".def.jwk (hidden/retired)"* ]]
}

@test "list_tang_keys is empty when the db dir has no keys" {
    [ -z "$(list_tang_keys)" ]
}

@test "rotate_tang_keys returns 2 when the helper script cannot be found" {
    WARDEN_TANGD_ROTATE_KEYS_CANDIDATES="/does/not/exist" run bash -c "
        source '${WARDEN_ROOT}/lib/core/log.sh'
        source '${WARDEN_ROOT}/lib/core/exec.sh'
        WARDEN_LOG_DIR='${WARDEN_LOG_DIR}'
        log_init
        source '${WARDEN_ROOT}/lib/features/tang_rotate.sh'
        rotate_tang_keys
    "
    [ "$status" -eq 2 ]
}

@test "rotate_tang_keys invokes the located script with the db dir" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/tangd-rotate-keys" <<'EOF'
#!/usr/bin/env bash
echo "rotate-keys called with: $*"
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/bin/tangd-rotate-keys"
    WARDEN_TANGD_ROTATE_KEYS_CANDIDATES="/does/not/exist" PATH="${TEST_TMPDIR}/bin:${PATH}" run rotate_tang_keys
    [ "$status" -eq 0 ]
    grep -q "rotate Tang keys in ${WARDEN_TANG_DB_DIR}" "$WARDEN_LOG_FILE"
}
