#!/usr/bin/env bats

load '../helpers/setup'

setup() {
    warden_test_setup
    export WARDEN_ZFS_IMPORT_UNIT_TEMPLATE="${TEST_TMPDIR}/warden-zfs-import@.service"
}
teardown() { warden_test_teardown; }

@test "is_valid_zpool_name accepts a plain name" {
    is_valid_zpool_name "data-disk"
}

@test "is_valid_zpool_name rejects a leading digit" {
    run is_valid_zpool_name "1disk"
    [ "$status" -ne 0 ]
}

@test "is_valid_zpool_name rejects reserved zpool words" {
    for word in mirror raidz raidz1 raidz2 raidz3 spare log cache draid; do
        run is_valid_zpool_name "$word"
        [ "$status" -ne 0 ]
    done
}

@test "is_valid_zpool_name accepts a name that merely contains a reserved word as a substring" {
    is_valid_zpool_name "mirrorpool"
    is_valid_zpool_name "my-cache-disk"
}

@test "create_zfs_pool in dry-run mode does not touch the device" {
    WARDEN_DRY_RUN=1 create_zfs_pool "/dev/fake" "testpass" "testpool" "/mnt/testpool"
    grep -q "DRY-RUN" "$WARDEN_LOG_FILE"
    grep -q "zpool create -m /mnt/testpool testpool" "$WARDEN_LOG_FILE"
}

@test "create_zfs_pool and the boot-time unit work end to end on a loop device" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for losetup/cryptsetup/zpool"
    fi
    if ! command -v zpool >/dev/null 2>&1; then
        skip "requires zfsutils-linux"
    fi
    local img loopdev mapper="warden-test-zpool-$$"
    img="${TEST_TMPDIR}/zfsdisk.img"
    truncate -s 200M "$img"
    loopdev="$(losetup -f --show "$img")"
    warden_test_luks_format "$loopdev" "test-passphrase-123"

    run create_zfs_pool "$loopdev" "test-passphrase-123" "$mapper" "/mnt/${mapper}"
    [ "$status" -eq 0 ]
    zpool list "$mapper"
    mount | grep -q "${mapper} on /mnt/${mapper}"

    zpool destroy "$mapper"
    cryptsetup close "$mapper" 2>/dev/null || true
    losetup -d "$loopdev"
    rmdir "/mnt/${mapper}" 2>/dev/null || true
}

@test "discover_unimported_zfs_pool_name finds a pool exported and reopened under a different mapper name" {
    # Regression coverage for menu 5's re-enrolment path: an existing
    # pool's name is not known in advance (unlike menu 4, which
    # chooses it), and isn't necessarily the same as whatever mapper
    # name it happens to be opened under right now -- e.g. after
    # moving a drive between hosts, or a throwaway probe name used
    # purely to inspect the device's contents.
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for losetup/cryptsetup/zpool"
    fi
    if ! command -v zpool >/dev/null 2>&1; then
        skip "requires zfsutils-linux"
    fi
    local img loopdev pool="warden-test-existing-$$" probe="warden-test-probe-$$"
    img="${TEST_TMPDIR}/existingzfs.img"
    truncate -s 200M "$img"
    loopdev="$(losetup -f --show "$img")"
    warden_test_luks_format "$loopdev" "test-passphrase-123"

    create_zfs_pool "$loopdev" "test-passphrase-123" "$pool" "/mnt/${pool}"
    zpool export "$pool"
    cryptsetup close "$pool"

    printf 'test-passphrase-123' | cryptsetup open --batch-mode "$loopdev" "$probe" -
    is_zfs_pool_member "/dev/mapper/${probe}"

    [ "$(discover_unimported_zfs_pool_name)" = "$pool" ]

    cryptsetup close "$probe"
    losetup -d "$loopdev"
    rmdir "/mnt/${pool}" 2>/dev/null || true
}

@test "discover_unimported_zfs_pool_name is empty when nothing is importable" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/zpool" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${TEST_TMPDIR}/bin/zpool"
    [ -z "$(PATH="${TEST_TMPDIR}/bin:${PATH}" discover_unimported_zfs_pool_name)" ]
}

@test "ensure_zfs_import_unit_template_installed writes the expected unit content" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for systemctl daemon-reload"
    fi
    WARDEN_DRY_RUN=0 ensure_zfs_import_unit_template_installed
    [ -f "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE" ]
    grep -qx 'After=systemd-cryptsetup@%i.service' "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE"
    grep -qx 'Requires=systemd-cryptsetup@%i.service' "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE"
    grep -qx 'ExecStart=/usr/sbin/zpool import -N %i' "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE"
    grep -qx 'ExecStart=/usr/sbin/zfs mount -a' "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE"
    grep -qx 'WantedBy=multi-user.target' "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE"
}

@test "ensure_zfs_import_unit_template_installed is idempotent: second call is a no-op" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for systemctl daemon-reload"
    fi
    WARDEN_DRY_RUN=0 ensure_zfs_import_unit_template_installed
    WARDEN_DRY_RUN=0 ensure_zfs_import_unit_template_installed
    grep -q "already up to date, skipping" "$WARDEN_LOG_FILE"
}

@test "ensure_zfs_import_unit_template_installed backs up an existing different version" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for systemctl daemon-reload"
    fi
    printf 'stale content\n' > "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE"
    WARDEN_DRY_RUN=0 ensure_zfs_import_unit_template_installed
    grep -qx 'WantedBy=multi-user.target' "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE"
    [ "$(find "$WARDEN_BACKUP_DIR" -name 'warden-zfs-import@.service.*.bak' | wc -l)" -eq 1 ]
}

@test "ensure_zfs_import_unit_template_installed in dry-run mode does not write the file" {
    WARDEN_DRY_RUN=1 ensure_zfs_import_unit_template_installed
    [ ! -f "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE" ]
    grep -q "DRY-RUN" "$WARDEN_LOG_FILE"
}

@test "enable_zfs_import_unit installs the template and attempts to enable the instance" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for systemctl daemon-reload"
    fi
    # The template is written to a test-local path (WARDEN_ZFS_IMPORT_UNIT_TEMPLATE),
    # not a real systemd search path, so the real systemctl enable call
    # this makes cannot actually succeed here (the unit genuinely won't
    # be found) -- unlike the existing drop-in tests elsewhere, which
    # only ever extend an *already-existing* real system unit regardless
    # of where their own drop-in file lands. Just confirm the right
    # things were attempted, the same way disable_zfs_import_unit's test
    # does below.
    WARDEN_DRY_RUN=0 enable_zfs_import_unit "does-not-exist-$$" || true
    [ -f "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE" ]
    grep -q "enable warden-zfs-import@does-not-exist-$$.service" "$WARDEN_LOG_FILE"
}

@test "disable_zfs_import_unit calls systemctl disable --now on the specific instance" {
    disable_zfs_import_unit "somepool" || true
    grep -q "systemctl disable --now warden-zfs-import@somepool.service" "$WARDEN_LOG_FILE"
}

@test "is_zfs_pool_member is false for a device lsblk reports no fstype for" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
echo ""
EOF
    chmod +x "${TEST_TMPDIR}/bin/lsblk"
    PATH="${TEST_TMPDIR}/bin:${PATH}" run is_zfs_pool_member "/dev/fake"
    [ "$status" -ne 0 ]
}

@test "is_zfs_pool_member is true for a device lsblk reports zfs_member for" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
echo "zfs_member"
EOF
    chmod +x "${TEST_TMPDIR}/bin/lsblk"
    PATH="${TEST_TMPDIR}/bin:${PATH}" is_zfs_pool_member "/dev/fake"
}

@test "describe_zfs_pool_status reports not-imported for a pool that isn't currently imported" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/zpool" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${TEST_TMPDIR}/bin/zpool"
    local out
    out="$(PATH="${TEST_TMPDIR}/bin:${PATH}" describe_zfs_pool_status somepool)"
    [[ "$out" == *"not currently imported"* ]]
}

@test "describe_zfs_pool_status survives a bare assignment under set -e when the pool doesn't exist" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/zpool" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${TEST_TMPDIR}/bin/zpool"
    run env PATH="${TEST_TMPDIR}/bin:${PATH}" bash -c "
        set -euo pipefail
        source '${WARDEN_ROOT}/lib/core/log.sh'
        source '${WARDEN_ROOT}/lib/core/exec.sh'
        WARDEN_LOG_DIR='${WARDEN_LOG_DIR}'
        log_init
        source '${WARDEN_ROOT}/lib/features/zfs_pool.sh'
        out=\"\$(describe_zfs_pool_status somepool)\"
        echo 'SURVIVED'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"SURVIVED"* ]]
}
