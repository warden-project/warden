# tests/helpers/setup.bash — common bats setup for core lib tests
#
# Sourced by each *.bats file. Points WARDEN_LOG_DIR/WARDEN_BACKUP_DIR at
# a throwaway per-test tmpdir so tests never touch real system paths.

WARDEN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

warden_test_setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export WARDEN_LOG_DIR="${TEST_TMPDIR}/log"
    export WARDEN_BACKUP_DIR="${TEST_TMPDIR}/backup"
    export WARDEN_NO_WHIPTAIL=1
    export WARDEN_DRY_RUN=0

    source "${WARDEN_ROOT}/lib/core/log.sh"
    source "${WARDEN_ROOT}/lib/core/exec.sh"
    source "${WARDEN_ROOT}/lib/core/device.sh"
    source "${WARDEN_ROOT}/lib/core/confirm.sh"
    source "${WARDEN_ROOT}/lib/core/backup.sh"
    source "${WARDEN_ROOT}/lib/core/pkg.sh"
    source "${WARDEN_ROOT}/lib/core/net.sh"
    source "${WARDEN_ROOT}/lib/core/crypt_inventory.sh"
    source "${WARDEN_ROOT}/lib/tui/menu.sh"
    source "${WARDEN_ROOT}/lib/features/install.sh"
    source "${WARDEN_ROOT}/lib/features/status.sh"
    source "${WARDEN_ROOT}/lib/features/tang_server.sh"
    source "${WARDEN_ROOT}/lib/features/tang_bindings.sh"
    source "${WARDEN_ROOT}/lib/features/zfs_pool.sh"
    source "${WARDEN_ROOT}/lib/features/root_unlock.sh"
    source "${WARDEN_ROOT}/lib/features/luks_enroll.sh"
    source "${WARDEN_ROOT}/lib/features/luks_setup.sh"
    source "${WARDEN_ROOT}/lib/features/lateboot.sh"
    source "${WARDEN_ROOT}/lib/features/binding_rotate.sh"
    source "${WARDEN_ROOT}/lib/features/header_backup.sh"
    source "${WARDEN_ROOT}/lib/features/tang_rotate.sh"
    source "${WARDEN_ROOT}/lib/features/danger_erase.sh"
    source "${WARDEN_ROOT}/lib/features/uninstall.sh"
    source "${WARDEN_ROOT}/lib/features/health_check.sh"

    log_init
}

warden_test_teardown() {
    rm -rf "${TEST_TMPDIR}"
}

# warden_test_luks_format <dev> <passphrase> — for tests that need a
# real LUKS device but aren't testing format_luks_device itself, so
# they call cryptsetup directly rather than through the product code.
# Confirmed on real hardware: lsblk/blkid's cached view of a device
# can briefly lag behind cryptsetup succeeding, so any test that reads
# the device's UUID/FSTYPE right after formatting needs the same
# udevadm settle format_luks_device itself does -- otherwise the test
# is flaky (passes or fails depending on timing), not deterministic.
warden_test_luks_format() {
    local dev="$1" passphrase="$2"
    printf '%s' "$passphrase" | cryptsetup luksFormat --batch-mode "$dev" -
    udevadm settle
}
