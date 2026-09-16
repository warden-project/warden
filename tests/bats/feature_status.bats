#!/usr/bin/env bats

load '../helpers/setup'

setup() { warden_test_setup; }
teardown() { warden_test_teardown; }

@test "crypttab_mapper_for_uuid finds the mapper for a matching UUID" {
    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    printf 'data-disk UUID=abc-123 none luks,_netdev\n' > "$WARDEN_CRYPTTAB"
    [ "$(crypttab_mapper_for_uuid abc-123)" = "data-disk" ]
}

@test "crypttab_mapper_for_uuid returns empty for an unmanaged UUID" {
    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    printf 'data-disk UUID=abc-123 none luks,_netdev\n' > "$WARDEN_CRYPTTAB"
    [ -z "$(crypttab_mapper_for_uuid xyz-999)" ]
}

@test "crypttab_mapper_for_uuid ignores commented-out lines" {
    WARDEN_CRYPTTAB="${TEST_TMPDIR}/crypttab"
    printf '#data-disk UUID=abc-123 none luks,_netdev\n' > "$WARDEN_CRYPTTAB"
    [ -z "$(crypttab_mapper_for_uuid abc-123)" ]
}

@test "fstab_has_mapper detects a present entry" {
    WARDEN_FSTAB="${TEST_TMPDIR}/fstab"
    printf '/dev/mapper/data-disk /mnt/data ext4 defaults,nofail 0 2\n' > "$WARDEN_FSTAB"
    fstab_has_mapper data-disk
}

@test "fstab_has_mapper reports missing entry" {
    WARDEN_FSTAB="${TEST_TMPDIR}/fstab"
    printf '/dev/mapper/other-disk /mnt/other ext4 defaults,nofail 0 2\n' > "$WARDEN_FSTAB"
    run fstab_has_mapper data-disk
    [ "$status" -ne 0 ]
}

@test "extract_tang_urls pulls a single tang pin URL" {
    local out
    out="$(extract_tang_urls '1: tang '"'"'{"url":"http://tang.example.com:8080"}'"'"'')"
    [ "$out" = "http://tang.example.com:8080" ]
}

@test "extract_tang_urls pulls multiple URLs nested in an sss pin, de-duplicated" {
    local input='1: sss '"'"'{"t":1,"pins":{"tang":[{"url":"http://a.example.com"},{"url":"http://b.example.com"},{"url":"http://a.example.com"}]}}'"'"''
    local out
    out="$(extract_tang_urls "$input")"
    [ "$(echo "$out" | wc -l)" -eq 2 ]
    echo "$out" | grep -qx "http://a.example.com"
    echo "$out" | grep -qx "http://b.example.com"
}

@test "check_tang_reachability reports unreachable for a closed port" {
    run check_tang_reachability "http://127.0.0.1:1"
    [[ "$output" == "unreachable" ]]
}

@test "check_tang_reachability reports reachable and a millisecond figure for a successful response" {
    # Stub curl rather than backgrounding a real HTTP server: bats runs each
    # test in its own subshell and command substitution (used by both `run`
    # and check_tang_reachability itself) blocks until every inherited
    # write end of its output pipe closes -- including an unrelated
    # backgrounded server's, if one happens to still hold it open. That's a
    # bats/job-control interaction, not something check_tang_reachability
    # needs to account for, so stub the one external dependency instead.
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "0.123"
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/bin/curl"
    PATH="${TEST_TMPDIR}/bin:${PATH}" run check_tang_reachability "http://127.0.0.1:9"
    [ "$output" = "reachable 123ms" ]
}

@test "tailscale_ordering_dropins finds a matching drop-in" {
    WARDEN_SYSTEMD_SYSTEM_DIR="${TEST_TMPDIR}/systemd"
    mkdir -p "${WARDEN_SYSTEMD_SYSTEM_DIR}/systemd-cryptsetup@data\x2ddisk.service.d"
    cat > "${WARDEN_SYSTEMD_SYSTEM_DIR}/systemd-cryptsetup@data\x2ddisk.service.d/override.conf" <<'EOF'
[Unit]
After=tailscale-online.target
Wants=tailscale-online.target
EOF
    local out
    out="$(tailscale_ordering_dropins)"
    [ -n "$out" ]
}

@test "tailscale_ordering_dropins reports none when absent" {
    WARDEN_SYSTEMD_SYSTEM_DIR="${TEST_TMPDIR}/systemd-empty"
    mkdir -p "$WARDEN_SYSTEMD_SYSTEM_DIR"
    [ -z "$(tailscale_ordering_dropins)" ]
}

@test "unit_state reports 'not present' for a unit that doesn't exist" {
    [ "$(unit_state definitely-not-a-real-unit.service)" = "not present" ]
}

@test "unit_state reports 'active' for a known-running unit" {
    if ! systemctl list-unit-files cron.service --no-legend 2>/dev/null | grep -q .; then
        skip "cron.service not present on this machine"
    fi
    [ "$(unit_state cron.service)" = "active" ]
}

@test "luks_devices lists a throwaway loop-backed LUKS device" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for losetup/cryptsetup"
    fi
    local img loopdev
    img="${TEST_TMPDIR}/disk.img"
    truncate -s 64M "$img"
    loopdev="$(losetup -f --show "$img")"
    echo -n "testpassphrase" | cryptsetup luksFormat --batch-mode "$loopdev" -
    run luks_devices
    [[ "$output" == *"$loopdev"* ]]
    losetup -d "$loopdev"
}
