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

@test "run_clevis_luks_unbind invokes clevis with the expected arguments" {
    mkdir -p "${TEST_TMPDIR}/bin"
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
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/clevis" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${TEST_TMPDIR}/bin/clevis"
    PATH="${TEST_TMPDIR}/bin:${PATH}" run run_clevis_luks_unbind "/dev/fake" "2"
    [ "$status" -ne 0 ]
}
