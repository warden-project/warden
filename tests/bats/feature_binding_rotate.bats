#!/usr/bin/env bats

load '../helpers/setup'

setup() {
    warden_test_setup
    export WARDEN_STATE_DIR="${TEST_TMPDIR}/warden-state"
    export WARDEN_BINDINGS_FILE="${WARDEN_STATE_DIR}/tang-bindings.json"
}
teardown() { warden_test_teardown; }

SAMPLE_SLOTS=$'1: sss \'{"t":1,"pins":{"tang":[{"url":"http://a"},{"url":"http://b"}]}}\'\n2: tang \'{"url":"http://c"}\''

@test "parse_clevis_slots extracts exactly two slots from sample output" {
    local out
    out="$(parse_clevis_slots "$SAMPLE_SLOTS")"
    [ "$(echo "$out" | wc -l)" -eq 2 ]
}

@test "parse_clevis_slots produces exactly the expected slot/pintype pairs" {
    local out
    out="$(parse_clevis_slots "$SAMPLE_SLOTS")"
    [ "$(echo "$out" | cut -f1 | sort | tr '\n' ' ')" = "1 2 " ]
    [ "$(echo "$out" | awk -F'\t' '$1==1{print $2}')" = "sss" ]
    [ "$(echo "$out" | awk -F'\t' '$1==2{print $2}')" = "tang" ]
}

@test "describe_binding_slot summarises an sss slot with its threshold" {
    local out
    out="$(describe_binding_slot "sss" '{"t":1,"pins":{"tang":[{"url":"http://a"},{"url":"http://b"}]}}')"
    [ "$out" = "sss (threshold 1 of 2)" ]
}

@test "describe_binding_slot summarises a plain tang slot with its url" {
    local out
    out="$(describe_binding_slot "tang" '{"url":"http://c"}')"
    [ "$out" = "tang http://c" ]
}

@test "describe_binding_slot summarises a tpm2 slot" {
    [ "$(describe_binding_slot "tpm2" '{}')" = "tpm2" ]
}

@test "describe_slots reports 'no bindings' when clevis is not installed or device is unbound" {
    PATH="/nonexistent" run describe_slots "/dev/fake"
    [ "$output" = "(no Clevis bindings on this device)" ]
}

@test "describe_slots lists every slot when clevis luks list has output" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/clevis" <<EOF
#!/usr/bin/env bash
cat <<'INNER'
${SAMPLE_SLOTS}
INNER
EOF
    chmod +x "${TEST_TMPDIR}/bin/clevis"
    local out
    out="$(PATH="${TEST_TMPDIR}/bin:${PATH}" describe_slots "/dev/fake")"
    [[ "$out" == *"Slot 1: sss (threshold 1 of 2)"* ]]
    [[ "$out" == *"Slot 2: tang http://c"* ]]
}

@test "slot_numbers lists just the numbers" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/clevis" <<EOF
#!/usr/bin/env bash
cat <<'INNER'
${SAMPLE_SLOTS}
INNER
EOF
    chmod +x "${TEST_TMPDIR}/bin/clevis"
    local out
    out="$(PATH="${TEST_TMPDIR}/bin:${PATH}" slot_numbers "/dev/fake")"
    [ "$out" = "$(printf '1\n2')" ]
}

@test "new_slots finds slots present after but not before" {
    local out
    out="$(new_slots "$(printf '1\n2')" "$(printf '1\n2\n3')")"
    [ "$out" = "3" ]
}

@test "new_slots is empty when nothing changed" {
    local out
    out="$(new_slots "$(printf '1\n2')" "$(printf '1\n2')")"
    [ -z "$out" ]
}

@test "new_slots handles an empty before-set (first binding ever)" {
    local out
    out="$(new_slots "" "$(printf '1')")"
    [ "$out" = "1" ]
}

# A realistic LUKS2 luksDump fixture: slot 0 is a bare passphrase (no
# token -- this is what a recovery passphrase or keyfile slot looks
# like), slots 1 and 2 have clevis tokens attached.
SAMPLE_LUKSDUMP=$'Keyslots:\n  0: luks2\n\tKey:        512 bits\n  1: luks2\n\tKey:        512 bits\n  2: luks2\n\tKey:        512 bits\nTokens:\n  0: clevis\n\tKeyslot:    1\n  1: clevis\n\tKeyslot:    2\nDigests:\n  0: pbkdf2\n\tKeyslots:   0 1 2'

_stub_cryptsetup_luksdump() {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/cryptsetup" <<EOF
#!/usr/bin/env bash
cat <<'INNER'
${SAMPLE_LUKSDUMP}
INNER
EOF
    chmod +x "${TEST_TMPDIR}/bin/cryptsetup"
}

@test "clevis_token_slots reads clevis-covered slots from luksDump, excluding a bare passphrase slot" {
    _stub_cryptsetup_luksdump
    local out
    out="$(PATH="${TEST_TMPDIR}/bin:${PATH}" clevis_token_slots "/dev/fake")"
    [ "$out" = "$(printf '1\n2')" ]
    [[ "$out" != *"0"* ]]
}

@test "slot_has_clevis_token is true for a clevis-covered slot" {
    _stub_cryptsetup_luksdump
    PATH="${TEST_TMPDIR}/bin:${PATH}" slot_has_clevis_token "/dev/fake" "1"
}

@test "slot_has_clevis_token is false for a bare passphrase slot" {
    _stub_cryptsetup_luksdump
    run env PATH="${TEST_TMPDIR}/bin:${PATH}" bash -c "source '${WARDEN_ROOT}/lib/features/binding_rotate.sh'; slot_has_clevis_token /dev/fake 0"
    [ "$status" -ne 0 ]
}

@test "run_clevis_luks_unbind invokes clevis with the expected arguments for a clevis-covered slot" {
    _stub_cryptsetup_luksdump
    cat > "${TEST_TMPDIR}/bin/clevis" <<'EOF'
#!/usr/bin/env bash
echo "clevis called with: $*"
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/bin/clevis"
    PATH="${TEST_TMPDIR}/bin:${PATH}" run run_clevis_luks_unbind "/dev/fake" "2"
    [[ "$output" == *"luks unbind -d /dev/fake -s 2 -f"* ]]
}

@test "run_clevis_luks_unbind propagates a failure exit status" {
    _stub_cryptsetup_luksdump
    cat > "${TEST_TMPDIR}/bin/clevis" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${TEST_TMPDIR}/bin/clevis"
    PATH="${TEST_TMPDIR}/bin:${PATH}" run run_clevis_luks_unbind "/dev/fake" "2"
    [ "$status" -ne 0 ]
}

@test "run_clevis_luks_unbind refuses (status 3) a slot with no clevis token, without ever calling clevis" {
    _stub_cryptsetup_luksdump
    local marker="${TEST_TMPDIR}/clevis_was_called"
    cat > "${TEST_TMPDIR}/bin/clevis" <<EOF
#!/usr/bin/env bash
touch "${marker}"
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/bin/clevis"
    PATH="${TEST_TMPDIR}/bin:${PATH}" run run_clevis_luks_unbind "/dev/fake" "0"
    [ "$status" -eq 3 ]
    [ ! -f "$marker" ]
    grep -q "REFUSED: slot 0" "$WARDEN_LOG_FILE"
}

@test "run_clevis_luks_unbind refuses an entirely nonexistent slot number too" {
    _stub_cryptsetup_luksdump
    PATH="${TEST_TMPDIR}/bin:${PATH}" run run_clevis_luks_unbind "/dev/fake" "99"
    [ "$status" -eq 3 ]
}

@test "binding_action_rotate uses the ZFS-aware test-unlock for a device with an enabled import unit" {
    # Not a full interactive test (whiptail-dependent, same as the
    # menu 4/5 equivalents); confirms the wiring exists for the same
    # bug class found and fixed in menu 4/5's enrolment wizard: a
    # ZFS-backed device is already open under its real mapper name
    # (the pool is imported there), so the generic test-unlock
    # (test_unlock_and_cleanup) fails outright with "Cannot use device
    # ... which is in use" -- unrelated to whether the new binding
    # actually works. Rotating a ZFS-backed device's binding would
    # have always reported "New binding did not verify" without this.
    local body
    body="$(declare -f binding_action_rotate)"
    [[ "$body" == *'is_systemd_unit_enabled "warden-zfs-import@'* ]]
    [[ "$body" == *'test_unlock_and_cleanup_zfs'* ]]
}
