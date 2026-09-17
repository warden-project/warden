#!/usr/bin/env bats

load '../helpers/setup'

setup() {
    warden_test_setup
    export WARDEN_STATE_DIR="${TEST_TMPDIR}/warden-state"
    export WARDEN_BINDINGS_FILE="${WARDEN_STATE_DIR}/tang-bindings.json"
    export WARDEN_SYSTEMD_SYSTEM_DIR="${TEST_TMPDIR}/systemd"
    mkdir -p "$WARDEN_SYSTEMD_SYSTEM_DIR"
}
teardown() { warden_test_teardown; }

@test "is_valid_mapper_name accepts a fresh, safe name" {
    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    : > "$WARDEN_CRYPTTAB"
    is_valid_mapper_name "data-disk_01"
}

@test "is_valid_mapper_name rejects unsafe characters" {
    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    : > "$WARDEN_CRYPTTAB"
    run is_valid_mapper_name "data disk; rm -rf /"
    [ "$status" -ne 0 ]
}

@test "is_valid_mapper_name rejects a name already in use" {
    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    printf 'data-disk UUID=abc none luks,_netdev\n' > "$WARDEN_CRYPTTAB"
    run is_valid_mapper_name "data-disk"
    [ "$status" -ne 0 ]
}

@test "build_crypttab_line matches the documented format" {
    [ "$(build_crypttab_line data-disk abc-123)" = "data-disk UUID=abc-123 none luks,_netdev" ]
}

@test "build_fstab_line matches the documented format" {
    [ "$(build_fstab_line data-disk /mnt/data ext4)" = "/dev/mapper/data-disk /mnt/data ext4 defaults,nofail 0 2" ]
}

@test "load_trust_config_or_warn parses a saved single-tang config" {
    # command -v clevis is checked first; stub it present so this test
    # reaches the parsing logic under test rather than the (whiptail-
    # dependent, not headlessly testable) "clevis not installed" path.
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/clevis" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/bin/clevis"
    save_bindings_config '{"pin_type":"tang","pin_config":{"url":"http://a"},"addresses":[]}'
    local out pin_type pin_config
    out="$(PATH="${TEST_TMPDIR}/bin:${PATH}" load_trust_config_or_warn)"
    pin_type="${out%%$'\t'*}"
    pin_config="${out#*$'\t'}"
    [ "$pin_type" = "tang" ]
    [[ "$pin_config" == *'"url": "http://a"'* ]]
}

@test "unmanaged_luks_devices excludes devices already in crypttab" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for losetup/cryptsetup"
    fi
    local img loopdev uuid
    img="${TEST_TMPDIR}/disk.img"
    truncate -s 64M "$img"
    loopdev="$(losetup -f --show "$img")"
    echo -n "testpassphrase" | cryptsetup luksFormat --batch-mode "$loopdev" -
    uuid="$(uuid_for_device "$loopdev")"

    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    : > "$WARDEN_CRYPTTAB"
    run unmanaged_luks_devices
    [[ "$output" == *"$loopdev"* ]]

    printf 'already-managed UUID=%s none luks,_netdev\n' "$uuid" > "$WARDEN_CRYPTTAB"
    run unmanaged_luks_devices
    [[ "$output" != *"$loopdev"* ]]

    losetup -d "$loopdev"
}

@test "unmanaged_luks_devices excludes the current root device even if unmanaged" {
    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    : > "$WARDEN_CRYPTTAB"
    local root_src
    root_src="$(findmnt -no SOURCE /)"
    run unmanaged_luks_devices
    [[ "$output" != *"$root_src"* ]]
}

@test "run_clevis_luks_bind invokes clevis with a keyfile path, never the passphrase itself" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/clevis" <<'EOF'
#!/usr/bin/env bash
echo "clevis called with: $*"
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/bin/clevis"
    PATH="${TEST_TMPDIR}/bin:${PATH}" run_clevis_luks_bind "/dev/fake" "super-secret-passphrase" "tang" '{"url":"http://x"}'
    run grep -q "super-secret-passphrase" "$WARDEN_LOG_FILE"
    [ "$status" -ne 0 ]
    grep -q "bind clevis tang pin to /dev/fake" "$WARDEN_LOG_FILE"
}

@test "run_clevis_luks_bind shreds the passphrase keyfile after use" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/clevis" <<'EOF'
#!/usr/bin/env bash
# Record the keyfile path (the argument following -k) so the test can
# check it's gone afterward.
prev=""
for arg in "$@"; do
    if [ "$prev" = "-k" ]; then
        echo "$arg" > "${WARDEN_TEST_KEYFILE_RECORD}"
    fi
    prev="$arg"
done
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/bin/clevis"
    export WARDEN_TEST_KEYFILE_RECORD="${TEST_TMPDIR}/recorded_keyfile_path"
    PATH="${TEST_TMPDIR}/bin:${PATH}" run_clevis_luks_bind "/dev/fake" "pw" "tang" '{}'
    local keyfile
    keyfile="$(cat "$WARDEN_TEST_KEYFILE_RECORD")"
    [ ! -f "$keyfile" ]
}

@test "run_clevis_luks_bind propagates a failure exit status" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/clevis" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${TEST_TMPDIR}/bin/clevis"
    PATH="${TEST_TMPDIR}/bin:${PATH}" run run_clevis_luks_bind "/dev/fake" "pw" "tang" '{}'
    [ "$status" -ne 0 ]
}

@test "test_unlock_and_cleanup reports failed when clevis unlock fails" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/clevis" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${TEST_TMPDIR}/bin/clevis"
    PATH="${TEST_TMPDIR}/bin:${PATH}" run test_unlock_and_cleanup "/dev/fake"
    # test_unlock_and_cleanup routes the unlock attempt through run_cmd,
    # which always echoes the wrapped command's (here empty) captured
    # output ahead of the final ok/failed line -- check the last line,
    # not the whole multi-line $output.
    [ "${lines[-1]}" = "failed" ]
}

@test "trust_config_has_tailscale is true when any address is flagged" {
    trust_config_has_tailscale '{"addresses":[{"url":"http://a","is_tailscale":false},{"url":"http://b","is_tailscale":true}]}'
}

@test "trust_config_has_tailscale is false when no address is flagged" {
    run trust_config_has_tailscale '{"addresses":[{"url":"http://a","is_tailscale":false}]}'
    [ "$status" -ne 0 ]
}

@test "trust_config_has_tailscale is false for an empty addresses list" {
    run trust_config_has_tailscale '{"addresses":[]}'
    [ "$status" -ne 0 ]
}

@test "cryptsetup_dropin_dir systemd-escapes a mapper name with a hyphen" {
    local out
    out="$(cryptsetup_dropin_dir "data-disk")"
    [[ "$out" == *'systemd-cryptsetup@data\x2ddisk.service.d' ]]
}

@test "ensure_tailscale_ordering_dropin in dry-run mode does not write the file" {
    WARDEN_DRY_RUN=1 ensure_tailscale_ordering_dropin "data-disk"
    [ ! -d "$(cryptsetup_dropin_dir data-disk)" ]
    grep -q "DRY-RUN" "$WARDEN_LOG_FILE"
}

@test "ensure_tailscale_ordering_dropin writes the expected unit ordering" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for systemctl daemon-reload"
    fi
    WARDEN_DRY_RUN=0 ensure_tailscale_ordering_dropin "data-disk"
    local file="$(cryptsetup_dropin_dir data-disk)/override.conf"
    grep -qx "After=tailscale-online.target" "$file"
    grep -qx "Wants=tailscale-online.target" "$file"
}

@test "ensure_tailscale_ordering_dropin is idempotent: second call is a no-op" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for systemctl daemon-reload"
    fi
    WARDEN_DRY_RUN=0 ensure_tailscale_ordering_dropin "data-disk"
    WARDEN_DRY_RUN=0 ensure_tailscale_ordering_dropin "data-disk"
    grep -q "already present for data-disk, skipping" "$WARDEN_LOG_FILE"
}
