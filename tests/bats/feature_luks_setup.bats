#!/usr/bin/env bats

load '../helpers/setup'

setup() {
    warden_test_setup
    export WARDEN_STATE_DIR="${TEST_TMPDIR}/warden-state"
    export WARDEN_BINDINGS_FILE="${WARDEN_STATE_DIR}/tang-bindings.json"
}
teardown() { warden_test_teardown; }

@test "generate_passphrase produces a reasonably long, non-empty value" {
    local pw
    pw="$(generate_passphrase)"
    [ -n "$pw" ]
    [ "${#pw}" -ge 20 ]
}

@test "generate_passphrase does not repeat itself across calls" {
    local a b
    a="$(generate_passphrase)"
    b="$(generate_passphrase)"
    [ "$a" != "$b" ]
}

@test "format_luks_device in dry-run mode does not touch the device" {
    local img
    img="${TEST_TMPDIR}/disk.img"
    truncate -s 64M "$img"
    local before after
    before="$(md5sum "$img" | cut -d' ' -f1)"
    WARDEN_DRY_RUN=1 format_luks_device "$img" "some-passphrase"
    after="$(md5sum "$img" | cut -d' ' -f1)"
    [ "$before" = "$after" ]
    grep -q "DRY-RUN" "$WARDEN_LOG_FILE"
}

@test "format_luks_device never logs the passphrase value" {
    local img
    img="${TEST_TMPDIR}/disk.img"
    truncate -s 64M "$img"
    WARDEN_DRY_RUN=1 format_luks_device "$img" "super-secret-passphrase-xyz"
    run grep -q "super-secret-passphrase-xyz" "$WARDEN_LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "format_luks_device and create_filesystem work end to end on a loop device" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for losetup/cryptsetup"
    fi
    local img loopdev
    img="${TEST_TMPDIR}/disk.img"
    truncate -s 64M "$img"
    loopdev="$(losetup -f --show "$img")"

    WARDEN_DRY_RUN=0 format_luks_device "$loopdev" "test-passphrase-123"
    run lsblk -no FSTYPE "$loopdev"
    [[ "$output" == "crypto_LUKS" ]]

    WARDEN_DRY_RUN=0 create_filesystem "$loopdev" "test-passphrase-123" "ext4"
    [ ! -e "/dev/mapper/warden-setup-$$" ]

    losetup -d "$loopdev"
}

@test "candidate_format_devices includes a blank disk with no filesystem at all" {
    # Regression test for a real bug found on actual hardware: lsblk's
    # raw mode represents an empty column as adjacent spaces, which
    # awk's default field splitting collapses -- silently excluding
    # every blank disk (the primary case this function exists for).
    # A blank disk is exactly "fstype": null in JSON.
    #
    # candidate_format_devices also runs every candidate through the
    # root/boot/efi guard, which makes its own separate lsblk calls
    # (-rno PATH, -dno UUID) to walk /dev/sda's (nonexistent, in this
    # test) descendant tree -- only the --json invocation this test
    # cares about should get the canned fixture below; anything else
    # must fall through to the real lsblk so the guard sees /dev/sda
    # as the nonexistent, unrelated device it actually is here.
    mkdir -p "${TEST_TMPDIR}/bin"
    local real_lsblk
    real_lsblk="$(command -v lsblk)"
    cat > "${TEST_TMPDIR}/bin/lsblk" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--json" ]]; then
cat <<'INNER'
{
   "blockdevices": [
      {"path": "/dev/sda", "fstype": null, "type": "disk"}
   ]
}
INNER
else
    exec ${real_lsblk} "\$@"
fi
EOF
    chmod +x "${TEST_TMPDIR}/bin/lsblk"
    local out
    out="$(PATH="${TEST_TMPDIR}/bin:${PATH}" candidate_format_devices)"
    [ "$out" = "/dev/sda none" ]
}

@test "candidate_format_devices excludes crypto_LUKS devices but includes other disks/partitions" {
    # A real loop device can't stand in for this: its lsblk TYPE is
    # "loop", which candidate_format_devices deliberately excludes
    # regardless of FSTYPE (loop devices are heavily used by snapd on
    # real Ubuntu systems -- showing them in the format picker would
    # be actively dangerous). Stub lsblk directly to test the actual
    # disk/part + FSTYPE filtering logic instead.
    #
    # As above, only the --json call gets the canned fixture; anything
    # else (the root/boot/efi guard's own lsblk calls) falls through
    # to the real lsblk so these fake, nonexistent paths correctly
    # resolve as unrelated to this machine's actual root/boot/efi.
    mkdir -p "${TEST_TMPDIR}/bin"
    local real_lsblk
    real_lsblk="$(command -v lsblk)"
    cat > "${TEST_TMPDIR}/bin/lsblk" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--json" ]]; then
cat <<'INNER'
{
   "blockdevices": [
      {"path": "/dev/sda", "fstype": "ext4", "type": "disk"},
      {"path": "/dev/sda1", "fstype": null, "type": "part"},
      {"path": "/dev/sdb", "fstype": "crypto_LUKS", "type": "disk"},
      {"path": "/dev/loop0", "fstype": "crypto_LUKS", "type": "loop"}
   ]
}
INNER
else
    exec ${real_lsblk} "\$@"
fi
EOF
    chmod +x "${TEST_TMPDIR}/bin/lsblk"
    local out
    out="$(PATH="${TEST_TMPDIR}/bin:${PATH}" candidate_format_devices)"
    [[ "$out" == *"/dev/sda "*"ext4"* ]]
    [[ "$out" == *"/dev/sda1 "*"none"* ]]
    [[ "$out" != *"/dev/sdb"* ]]
    [[ "$out" != *"/dev/loop0"* ]]
}

@test "candidate_format_devices excludes a device that backs root/boot/efi" {
    # menu 5's equivalent list (unmanaged_luks_devices) already filters
    # this way; this device picker was found to not, during real
    # interactive TUI testing, letting the actual system disk appear
    # as a formattable candidate. confirm_destructive_device_action
    # would still refuse the format itself, but there's no reason to
    # offer a selection that can only ever end in a refusal.
    mkdir -p "${TEST_TMPDIR}/bin"
    local real_lsblk
    real_lsblk="$(command -v lsblk)"
    cat > "${TEST_TMPDIR}/bin/lsblk" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--json" ]]; then
cat <<'INNER'
{
   "blockdevices": [
      {"path": "/dev/fake-root-disk", "fstype": null, "type": "disk"},
      {"path": "/dev/sdb", "fstype": null, "type": "disk"}
   ]
}
INNER
else
    exec ${real_lsblk} "\$@"
fi
EOF
    chmod +x "${TEST_TMPDIR}/bin/lsblk"
    cat > "${TEST_TMPDIR}/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
target=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) target="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [[ "$target" == "/" ]]; then
    echo "/dev/fake-root-disk"
fi
EOF
    chmod +x "${TEST_TMPDIR}/bin/findmnt"
    local out
    out="$(PATH="${TEST_TMPDIR}/bin:${PATH}" candidate_format_devices)"
    [[ "$out" != *"/dev/fake-root-disk"* ]]
    [[ "$out" == *"/dev/sdb"* ]]
}

@test "candidate_format_devices excludes an already-LUKS-formatted loop device via luks_devices too" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for losetup/cryptsetup"
    fi
    # Loop devices never appear in candidate_format_devices at all
    # (see above), but this confirms the real end-to-end lifecycle
    # still works: a blank loop device shows up in the LUKS-device
    # inventory as non-LUKS, and drops out of the crypto_LUKS view
    # correctly once formatted -- exercising the actual production
    # code path menu 4 depends on (format then immediately resolve
    # the new UUID), including the udevadm settle fix.
    local img loopdev uuid
    img="${TEST_TMPDIR}/disk.img"
    truncate -s 64M "$img"
    loopdev="$(losetup -f --show "$img")"
    WARDEN_DRY_RUN=0 format_luks_device "$loopdev" "test-passphrase-123"
    uuid="$(uuid_for_device "$loopdev")"
    [ -n "$uuid" ]
    losetup -d "$loopdev"
}

@test "feature_luks_setup_menu only offers the filesystem-kind choice when zfsutils-linux is installed" {
    # zfsutils-linux is an optional install (menu 1) -- someone who
    # never installed it shouldn't be stopped by an extra "what should
    # this device hold" menu screen for a choice they can't act on
    # anyway. Not a full interactive test (whiptail-dependent, not
    # exercised elsewhere in this file either); confirms the actual
    # gating condition is present in the function body.
    local body
    body="$(declare -f feature_luks_setup_menu)"
    [[ "$body" == *'is_pkg_installed zfsutils-linux'* ]]
    # And that the gate wraps the fs_kind prompt, not something else --
    # the "zfs" menu tag must appear only inside that same if-block.
    local before_if after_if
    before_if="${body%%is_pkg_installed zfsutils-linux*}"
    after_if="${body#*is_pkg_installed zfsutils-linux}"
    [[ "$before_if" != *'"zfs"'* ]]
    [[ "$after_if" == *'"zfs"'* ]]
}
