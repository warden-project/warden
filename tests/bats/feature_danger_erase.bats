#!/usr/bin/env bats

load '../helpers/setup'

setup() { warden_test_setup; }
teardown() { warden_test_teardown; }

SAMPLE_LUKSDUMP=$'Keyslots:\n  0: luks2\n\tKey:        512 bits\n  1: luks2\n\tKey:        512 bits\nTokens:\n  0: clevis\n\tKeyslot:    1\nDigests:\n  0: pbkdf2'

_stub_bins() {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/cryptsetup" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "luksDump" ]; then
cat <<'INNER'
${SAMPLE_LUKSDUMP}
INNER
elif [ "\$1" = "luksErase" ]; then
    echo "ERASE_ARGS: \$*"
    exit 0
fi
EOF
    chmod +x "${TEST_TMPDIR}/bin/cryptsetup"
    cat > "${TEST_TMPDIR}/bin/clevis" <<'EOF'
#!/usr/bin/env bash
echo "1: tang '{\"url\":\"http://a\"}'"
EOF
    chmod +x "${TEST_TMPDIR}/bin/clevis"
}

@test "describe_device_for_erase shows both Clevis bindings and the raw keyslot inventory" {
    _stub_bins
    local out
    out="$(PATH="${TEST_TMPDIR}/bin:${PATH}" describe_device_for_erase "/dev/fake")"
    [[ "$out" == *"Slot 1: tang http://a"* ]]
    [[ "$out" == *"0: luks2"* ]]
    [[ "$out" == *"1: luks2"* ]]
}

@test "describe_device_for_erase stops the raw dump at the next section" {
    _stub_bins
    local out
    out="$(PATH="${TEST_TMPDIR}/bin:${PATH}" describe_device_for_erase "/dev/fake")"
    [[ "$out" != *"pbkdf2"* ]]
    [[ "$out" != *"Tokens:"* ]]
}

@test "run_luks_erase invokes cryptsetup luksErase in batch mode" {
    _stub_bins
    PATH="${TEST_TMPDIR}/bin:${PATH}" run run_luks_erase "/dev/fake"
    [[ "$output" == *"ERASE_ARGS: luksErase --batch-mode /dev/fake"* ]]
}

@test "run_luks_erase in dry-run mode does not call cryptsetup" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/cryptsetup" <<'EOF'
#!/usr/bin/env bash
touch "TEST_MARKER_SHOULD_NOT_EXIST"
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/bin/cryptsetup"
    cd "$TEST_TMPDIR"
    WARDEN_DRY_RUN=1 PATH="${TEST_TMPDIR}/bin:${PATH}" run_luks_erase "/dev/fake"
    [ ! -f "TEST_MARKER_SHOULD_NOT_EXIST" ]
    grep -q "DRY-RUN" "$WARDEN_LOG_FILE"
}

@test "run_luks_erase propagates a failure exit status" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/cryptsetup" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${TEST_TMPDIR}/bin/cryptsetup"
    PATH="${TEST_TMPDIR}/bin:${PATH}" run run_luks_erase "/dev/fake"
    [ "$status" -ne 0 ]
}
