#!/usr/bin/env bats

load '../helpers/setup'

setup() {
    warden_test_setup
    export WARDEN_STATE_DIR="${TEST_TMPDIR}/warden-state"
    export WARDEN_BINDINGS_FILE="${WARDEN_STATE_DIR}/tang-bindings.json"
}
teardown() { warden_test_teardown; }

@test "parse_host_port splits host and port" {
    run parse_host_port "tang.example.com:7500"
    [ "$output" = "$(printf 'tang.example.com\t7500')" ]
}

@test "parse_host_port defaults to port 80 when none given" {
    run parse_host_port "tang.example.com"
    [ "$output" = "$(printf 'tang.example.com\t80')" ]
}

@test "is_cgnat_address matches the Tailscale CGNAT range" {
    is_cgnat_address "100.64.0.1"
    is_cgnat_address "100.100.50.50"
    is_cgnat_address "100.127.255.255"
}

@test "is_cgnat_address rejects addresses outside the range" {
    run is_cgnat_address "100.63.255.255"
    [ "$status" -ne 0 ]
    run is_cgnat_address "100.128.0.0"
    [ "$status" -ne 0 ]
    run is_cgnat_address "192.168.1.1"
    [ "$status" -ne 0 ]
    run is_cgnat_address "tang.example.com"
    [ "$status" -ne 0 ]
}

@test "tailscale_peer_match finds a peer by TailscaleIPs" {
    local json='{"Self":{"TailscaleIPs":["100.64.1.1"],"DNSName":"me.tail1234.ts.net."},"Peer":{"x":{"TailscaleIPs":["100.64.1.2"],"DNSName":"tang-box.tail1234.ts.net."}}}'
    tailscale_peer_match "100.64.1.2" "$json"
}

@test "tailscale_peer_match finds a peer by DNSName" {
    local json='{"Peer":{"x":{"TailscaleIPs":["100.64.1.2"],"DNSName":"tang-box.tail1234.ts.net."}}}'
    tailscale_peer_match "tang-box.tail1234.ts.net" "$json"
    tailscale_peer_match "tang-box" "$json"
}

@test "tailscale_peer_match returns false for an unrelated host" {
    local json='{"Peer":{"x":{"TailscaleIPs":["100.64.1.2"],"DNSName":"tang-box.tail1234.ts.net."}}}'
    run tailscale_peer_match "unrelated.example.com" "$json"
    [ "$status" -ne 0 ]
}

@test "classify_tailscale confirms via the tailscale CLI when it matches" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
echo '{"Peer":{"x":{"TailscaleIPs":["100.64.1.2"],"DNSName":"tang-box.tail1234.ts.net."}}}'
EOF
    chmod +x "${TEST_TMPDIR}/bin/tailscale"
    PATH="${TEST_TMPDIR}/bin:${PATH}" run classify_tailscale "100.64.1.2"
    [ "$output" = "confirmed" ]
}

@test "classify_tailscale says no via the CLI when there's no match, even in CGNAT range" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
echo '{"Peer":{}}'
EOF
    chmod +x "${TEST_TMPDIR}/bin/tailscale"
    PATH="${TEST_TMPDIR}/bin:${PATH}" run classify_tailscale "100.64.1.2"
    [ "$output" = "no" ]
}

@test "classify_tailscale falls back to the CGNAT heuristic without the CLI" {
    PATH="/nonexistent" run classify_tailscale "100.64.1.2"
    [ "$output" = "heuristic" ]
}

@test "classify_tailscale says no without the CLI for a non-CGNAT address" {
    PATH="/nonexistent" run classify_tailscale "192.168.1.1"
    [ "$output" = "no" ]
}

@test "build_tang_pin_config produces a valid single-pin JSON config" {
    run build_tang_pin_config "http://tang.example.com:80"
    [[ "$output" == *'"url": "http://tang.example.com:80"'* ]]
}

@test "build_tpm2_pin_config produces an empty object" {
    [ "$(build_tpm2_pin_config)" = "{}" ]
}

@test "build_sss_pin_config builds a threshold config with multiple tang urls" {
    run build_sss_pin_config 1 "$(printf 'http://a\nhttp://b')" 0
    [[ "$output" == *'"t": 1'* ]]
    [[ "$output" == *'"url": "http://a"'* ]]
    [[ "$output" == *'"url": "http://b"'* ]]
    [[ "$output" != *'tpm2'* ]]
}

@test "build_sss_pin_config includes a tpm2 pin when requested" {
    run build_sss_pin_config 2 "$(printf 'http://a\nhttp://b')" 1
    [[ "$output" == *'"tpm2": [{}]'* ]]
}

@test "group_same_server does not group distinct bodies" {
    printf 'http://a\tBODY1\nhttp://c\tBODY2\n' | group_same_server > "${TEST_TMPDIR}/out"
    [ ! -s "${TEST_TMPDIR}/out" ]
}

@test "group_same_server output actually contains both urls for a matched group" {
    local out
    out="$(printf 'http://a\tBODY1\nhttp://b\tBODY1\nhttp://c\tBODY2\n' | group_same_server)"
    [[ "$out" == *"http://a"* ]]
    [[ "$out" == *"http://b"* ]]
    [[ "$out" != *"http://c"* ]]
}

@test "describe_saved_bindings summarises a plain single-tang config" {
    local out
    out="$(describe_saved_bindings '{"pin_type":"tang","pin_config":{"url":"http://a"},"addresses":[{"url":"http://a","is_tailscale":false,"detection_method":"no"}]}')"
    [[ "$out" == *"Pin type: tang"* ]]
    [[ "$out" == *"http://a"* ]]
    [[ "$out" != *"Tailscale"* ]]
}

@test "describe_saved_bindings shows the sss threshold and flags tailscale addresses" {
    local out
    out="$(describe_saved_bindings '{"pin_type":"sss","pin_config":{"t":1,"pins":{"tang":[{"url":"http://a"},{"url":"http://b"}]}},"addresses":[{"url":"http://a","is_tailscale":false,"detection_method":"no"},{"url":"http://b","is_tailscale":true,"detection_method":"confirmed"}]}')"
    [[ "$out" == *"threshold 1 of 2"* ]]
    [[ "$out" == *"http://b (Tailscale, confirmed)"* ]]
    [[ "$out" != *"http://a (Tailscale"* ]]
}

@test "describe_saved_bindings summarises a tpm2-only config" {
    local out
    out="$(describe_saved_bindings '{"pin_type":"tpm2","pin_config":{},"addresses":[]}')"
    [[ "$out" == *"tpm2"* ]]
}

@test "save_bindings_config writes the file and backs up on a second save" {
    save_bindings_config '{"pin_type":"tang"}'
    [ -f "$WARDEN_BINDINGS_FILE" ]
    grep -q '"pin_type":"tang"' "$WARDEN_BINDINGS_FILE"
    save_bindings_config '{"pin_type":"sss"}'
    grep -q '"pin_type":"sss"' "$WARDEN_BINDINGS_FILE"
    [ "$(find "$WARDEN_BACKUP_DIR" -name 'tang-bindings.json.*.bak' | wc -l)" -eq 1 ]
}

@test "load_bindings_config returns empty when nothing saved yet" {
    [ -z "$(load_bindings_config)" ]
}

@test "load_bindings_config round-trips a saved config" {
    save_bindings_config '{"pin_type":"tang"}'
    [[ "$(load_bindings_config)" == *'"pin_type":"tang"'* ]]
}

@test "load_bindings_config survives a bare assignment under set -e when nothing is saved" {
    # Regression test for a real crash found on real hardware: bats
    # itself never runs test bodies under `set -e`, so this exact bug
    # (load_bindings_config returning non-zero via a `[[ -f ]] && cat`
    # short-circuit, silently killing the whole bin/warden process on
    # `existing="$(load_bindings_config)"`) was invisible to every
    # other test in this file. This reproduces the actual failure mode.
    run bash -c "
        set -euo pipefail
        source '${WARDEN_ROOT}/lib/core/log.sh'
        source '${WARDEN_ROOT}/lib/core/exec.sh'
        source '${WARDEN_ROOT}/lib/core/backup.sh'
        WARDEN_LOG_DIR='${WARDEN_LOG_DIR}'
        WARDEN_BINDINGS_FILE='${WARDEN_BINDINGS_FILE}'
        log_init
        source '${WARDEN_ROOT}/lib/features/tang_bindings.sh'
        existing=\"\$(load_bindings_config)\"
        echo 'SURVIVED'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"SURVIVED"* ]]
}

@test "tailscale_status_json survives a bare assignment under set -e when tailscale fails" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${TEST_TMPDIR}/bin/tailscale"
    run env PATH="${TEST_TMPDIR}/bin:${PATH}" bash -c "
        set -euo pipefail
        source '${WARDEN_ROOT}/lib/core/log.sh'
        source '${WARDEN_ROOT}/lib/core/exec.sh'
        WARDEN_LOG_DIR='${WARDEN_LOG_DIR}'
        log_init
        source '${WARDEN_ROOT}/lib/features/tang_bindings.sh'
        json=\"\$(tailscale_status_json)\"
        echo 'SURVIVED'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"SURVIVED"* ]]
}

@test "fetch_tang_adv survives a bare assignment under set -e for an unreachable url" {
    run bash -c "
        set -euo pipefail
        source '${WARDEN_ROOT}/lib/core/log.sh'
        WARDEN_LOG_DIR='${WARDEN_LOG_DIR}'
        log_init
        source '${WARDEN_ROOT}/lib/core/net.sh'
        body=\"\$(fetch_tang_adv 'http://127.0.0.1:1')\"
        echo 'SURVIVED'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"SURVIVED"* ]]
}
