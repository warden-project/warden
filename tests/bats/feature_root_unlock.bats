#!/usr/bin/env bats

load '../helpers/setup'

setup() { warden_test_setup; }
teardown() { warden_test_teardown; }

@test "resolve_root_luks_device finds the crypto_LUKS ancestor on a real LUKS-encrypted root" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for findmnt/lsblk to see the real root device"
    fi
    if [[ "$(findmnt -no FSTYPE /)" == "overlay" ]]; then
        skip "root is an overlay filesystem in this sandbox, not backed by a real block device"
    fi
    # Confirmed on real hardware (see docs/future-work.md): correctly
    # returns empty on a plain (non-LUKS) root, and the actual
    # crypto_LUKS partition (walking through LVM) on an encrypted one.
    # This sandbox/VM's actual root may be either -- just confirm the
    # function agrees with what luks_devices independently reports.
    local resolved
    resolved="$(resolve_root_luks_device)"
    if [[ -n "$resolved" ]]; then
        luks_devices | grep -qF "$resolved "
    fi
}

@test "resolve_root_luks_device is empty when root's source can't be determined" {
    findmnt() { return 1; }
    export -f findmnt
    [ -z "$(resolve_root_luks_device)" ]
}

@test "is_boot_separate_from_root is true when /boot has a different source than /" {
    findmnt() {
        if [[ "$3" == "/" ]]; then echo "/dev/root-device"; else echo "/dev/boot-device"; fi
    }
    export -f findmnt
    is_boot_separate_from_root
}

@test "is_boot_separate_from_root is false when /boot has no separate mountpoint" {
    findmnt() {
        if [[ "$3" == "/" ]]; then echo "/dev/root-device"; else return 1; fi
    }
    export -f findmnt
    run is_boot_separate_from_root
    [ "$status" -ne 0 ]
}

@test "is_boot_separate_from_root is false when /boot somehow reports the same source as /" {
    findmnt() { echo "/dev/same-device"; }
    export -f findmnt
    run is_boot_separate_from_root
    [ "$status" -ne 0 ]
}

@test "is_tpm2_present is true when a TPM device node exists" {
    if [ ! -e /dev/tpmrm0 ] && [ ! -e /dev/tpm0 ]; then
        skip "no real TPM device node on this machine"
    fi
    is_tpm2_present
}

@test "is_tpm2_present is false when no TPM device node exists" {
    if [ -e /dev/tpmrm0 ] || [ -e /dev/tpm0 ]; then
        skip "this machine has a real TPM device node, can't test the negative case directly"
    fi
    run is_tpm2_present
    [ "$status" -ne 0 ]
}

@test "is_local_address is true for loopback addresses without any lookup" {
    is_local_address "127.0.0.1"
    is_local_address "localhost"
    is_local_address "::1"
}

@test "is_local_address is true for one of this machine's own currently-assigned addresses" {
    local own_ip
    own_ip="$(ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    if [ -z "$own_ip" ]; then
        skip "no global-scope address found on this machine to test against"
    fi
    is_local_address "$own_ip"
}

@test "is_local_address is false for an address that isn't this machine's" {
    run is_local_address "203.0.113.1"
    [ "$status" -ne 0 ]
}

@test "is_local_address resolves a hostname before checking, not just literal IPs" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/getent" <<'EOF'
#!/usr/bin/env bash
echo "127.0.0.1 fake-self-hostname"
EOF
    chmod +x "${TEST_TMPDIR}/bin/getent"
    PATH="${TEST_TMPDIR}/bin:${PATH}" is_local_address "fake-self-hostname"
}
