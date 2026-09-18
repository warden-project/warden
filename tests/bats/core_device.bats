#!/usr/bin/env bats

load '../helpers/setup'

setup() { warden_test_setup; }
teardown() { warden_test_teardown; }

@test "uuid_for_device returns empty for a disk with partitions, not a child's UUID" {
    # Regression test for a real bug found on real hardware: without
    # -d (no-deps), `lsblk -no UUID <disk>` on a disk with partitions
    # lists the whole descendant tree in an order that put a *child's*
    # filesystem UUID first -- e.g. for a disk holding an LVM root,
    # this returned the root logical volume's UUID instead of the
    # disk's own (correctly empty) UUID.
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for losetup/partitioning"
    fi
    if ! command -v parted >/dev/null 2>&1; then
        skip "requires parted"
    fi
    local img loopdev
    img="${TEST_TMPDIR}/wholedisk2.img"
    truncate -s 32M "$img"
    loopdev="$(losetup -f --show -P "$img")"
    parted -s "$loopdev" mklabel gpt mkpart primary ext4 1MiB 100%
    udevadm settle
    mkfs.ext4 -F "${loopdev}p1" >/dev/null 2>&1
    udevadm settle

    [ -z "$(uuid_for_device "$loopdev")" ]
    [ -n "$(uuid_for_device "${loopdev}p1")" ]

    losetup -d "$loopdev"
}

@test "is_system_critical flags the current root device" {
    local root_src
    root_src="$(findmnt -no SOURCE /)"
    is_system_critical "$root_src"
}

@test "guard_not_system_critical refuses the current root device" {
    local root_src
    root_src="$(findmnt -no SOURCE /)"
    run guard_not_system_critical "$root_src"
    [ "$status" -eq 1 ]
}

@test "is_system_critical flags a whole disk holding a critical partition, not just the partition itself" {
    # Regression test for a real bug found on real hardware: an earlier
    # version of this check only compared the target directly against
    # each mountpoint's *immediate* backing device, so it correctly
    # caught e.g. an EFI partition itself but completely missed the
    # *whole disk* device holding it -- a partitioned disk is never
    # itself equal (by path or UUID) to any one of its own partitions.
    # Formatting that whole-disk device destroys the partition table
    # and everything on it, so it must be flagged just as critical.
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for losetup/partitioning"
    fi
    if ! command -v parted >/dev/null 2>&1; then
        skip "requires parted"
    fi
    local img loopdev
    img="${TEST_TMPDIR}/wholedisk.img"
    truncate -s 32M "$img"
    loopdev="$(losetup -f --show -P "$img")"
    parted -s "$loopdev" mklabel gpt mkpart primary ext4 1MiB 100%
    udevadm settle
    mkfs.ext4 -F "${loopdev}p1" >/dev/null 2>&1

    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/findmnt" <<EOF
#!/usr/bin/env bash
target=""
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --target) target="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [[ "\$target" == "/" ]]; then
    echo "${loopdev}p1"
fi
EOF
    chmod +x "${TEST_TMPDIR}/bin/findmnt"

    PATH="${TEST_TMPDIR}/bin:${PATH}" run is_system_critical "$loopdev"
    [ "$status" -eq 0 ]

    losetup -d "$loopdev"
}

@test "is_system_critical does not flag a throwaway loop-backed LUKS device" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for losetup/cryptsetup"
    fi
    local img loopdev
    img="${TEST_TMPDIR}/disk.img"
    truncate -s 64M "$img"
    loopdev="$(losetup -f --show "$img")"
    warden_test_luks_format "$loopdev" "testpassphrase"
    run is_system_critical "$loopdev"
    [ "$status" -eq 1 ]
    losetup -d "$loopdev"
}
