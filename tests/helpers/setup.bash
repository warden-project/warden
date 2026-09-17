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
    source "${WARDEN_ROOT}/lib/features/install.sh"
    source "${WARDEN_ROOT}/lib/features/status.sh"
    source "${WARDEN_ROOT}/lib/features/tang_server.sh"
    source "${WARDEN_ROOT}/lib/features/tang_bindings.sh"
    source "${WARDEN_ROOT}/lib/features/luks_enroll.sh"
    source "${WARDEN_ROOT}/lib/features/luks_setup.sh"
    source "${WARDEN_ROOT}/lib/features/lateboot.sh"

    log_init
}

warden_test_teardown() {
    rm -rf "${TEST_TMPDIR}"
}
