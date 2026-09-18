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
    # Must override the candidates to nonexistent paths: on a real
    # host with tang-common installed, /usr/libexec/tangd-rotate-keys
    # genuinely exists (confirmed on real hardware -- it's shipped by
    # tang-common, a dependency of tang, not by the tang package
    # itself), which would satisfy the primary check before this test
    # ever exercises the PATH fallback it's meant to test.
    WARDEN_TANGD_ROTATE_KEYS_CANDIDATES="/does/not/exist"
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

@test "rotate_tang_keys falls back to the manual procedure when no script is found" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for chown to match db dir ownership"
    fi
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/jose" <<'EOF'
#!/usr/bin/env bash
# minimal stand-in: just write something resembling a JWK.
# "${@: -1}" (note the space before -1) is bash's idiom for "the last
# positional argument" -- "${*: -1}" would instead string-slice the
# space-joined concatenation of all args, giving the last character.
if [ "$1" = "jwk" ] && [ "$2" = "gen" ]; then
    out="${@: -1}"
    echo '{"alg":"fake"}' > "$out"
fi
EOF
    chmod +x "${TEST_TMPDIR}/bin/jose"
    touch "${WARDEN_TANG_DB_DIR}/existing-old-key.jwk"
    WARDEN_TANGD_ROTATE_KEYS_CANDIDATES="/does/not/exist" PATH="${TEST_TMPDIR}/bin:${PATH}" run rotate_tang_keys
    [ "$status" -eq 0 ]
    [ ! -f "${WARDEN_TANG_DB_DIR}/existing-old-key.jwk" ]
    [ -f "${WARDEN_TANG_DB_DIR}/.existing-old-key.jwk" ]
    [ "$(find "${WARDEN_TANG_DB_DIR}" -maxdepth 1 -name '*.jwk' ! -name '.*' | wc -l)" -eq 2 ]
}

@test "current_tang_key_files lists only visible .jwk files" {
    touch "${WARDEN_TANG_DB_DIR}/visible.jwk"
    touch "${WARDEN_TANG_DB_DIR}/.hidden.jwk"
    local out
    out="$(current_tang_key_files "$WARDEN_TANG_DB_DIR")"
    [[ "$out" == *"visible.jwk"* ]]
    [[ "$out" != *".hidden.jwk"* ]]
}

@test "current_tang_key_files is empty for an empty directory" {
    [ -z "$(current_tang_key_files "$WARDEN_TANG_DB_DIR")" ]
}

@test "generate_tang_key in dry-run mode does not create a file" {
    WARDEN_DRY_RUN=1 generate_tang_key "ES512" "$WARDEN_TANG_DB_DIR"
    [ -z "$(current_tang_key_files "$WARDEN_TANG_DB_DIR")" ]
    grep -q "DRY-RUN" "$WARDEN_LOG_FILE"
}

@test "rotate_tang_keys_manual in dry-run mode touches nothing" {
    touch "${WARDEN_TANG_DB_DIR}/existing.jwk"
    WARDEN_DRY_RUN=1 rotate_tang_keys_manual "$WARDEN_TANG_DB_DIR"
    [ -f "${WARDEN_TANG_DB_DIR}/existing.jwk" ]
    [ "$(current_tang_key_files "$WARDEN_TANG_DB_DIR")" = "${WARDEN_TANG_DB_DIR}/existing.jwk" ]
}
