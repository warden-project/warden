# shellcheck shell=bash
# lib/features/zfs_pool.sh — ZFS pool support for menus 4/5
#
# Single-disk pools only: one LUKS device = one zpool, matching the
# existing 1:1 device model exactly (no mirror/raidz, no multi-device
# picker). The pool name reuses the crypttab mapper name -- one prompt,
# not two -- so is_valid_zpool_name only needs to add zpool's own extra
# restrictions on top of is_valid_mapper_name's existing check.
#
# See docs/future-work.md for the full design writeup, including two
# systemd ordering-cycle dead ends found via real reboot tests before
# landing on the per-device dedicated unit approach used here:
# ordering the shared zfs-import-cache.service/zfs-import-scan.service
# after remote-cryptsetup.target (or even after one specific device's
# cryptsetup unit) creates a genuine cycle on a system with snapd
# installed, because remote-cryptsetup.target's own dependency chain
# loops back through zfs-mount.service. A dedicated per-device unit,
# targeting multi-user.target rather than local-fs.target (which hits
# the same cycle class), avoids it entirely.

: "${WARDEN_ZFS_IMPORT_UNIT_TEMPLATE:=/etc/systemd/system/warden-zfs-import@.service}"

readonly WARDEN_ZFS_IMPORT_UNIT_CONTENT='[Unit]
Description=Warden: import ZFS pool %i after its LUKS device unlocks
After=systemd-cryptsetup@%i.service
Requires=systemd-cryptsetup@%i.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/zpool import -N %i
ExecStart=/usr/sbin/zfs mount -a

[Install]
WantedBy=multi-user.target
'

# Reserved zpool names that must never be accepted, even though they'd
# pass is_valid_mapper_name's plainer check (letters/digits/-/_ only).
readonly WARDEN_ZPOOL_RESERVED_NAMES="mirror raidz raidz1 raidz2 raidz3 spare log cache draid"

# is_valid_zpool_name <name> — zpool's own extra restrictions on top of
# is_valid_mapper_name: no leading digit, not a reserved word.
is_valid_zpool_name() {
    local name="$1" word
    [[ "$name" =~ ^[0-9] ]] && return 1
    for word in $WARDEN_ZPOOL_RESERVED_NAMES; do
        [[ "$name" == "$word" ]] && return 1
    done
    return 0
}

# create_zfs_pool <dev> <passphrase> <mapper> <mountpoint>
#
# Opens <dev> under its final, persistent mapper name -- unlike
# create_filesystem's throwaway-name-then-close approach for a plain
# filesystem, a zpool's name is fixed at creation and this design
# reuses the mapper name as the pool name, so the pool must be created
# against that exact mapper. Left open/imported/mounted afterward:
# zpool create naturally leaves a new pool imported, and there's no
# analogous "close it again until boot" step the way there is for a
# bare filesystem.
create_zfs_pool() {
    local dev="$1" passphrase="$2" mapper="$3" mountpoint="$4"
    if [[ "${WARDEN_DRY_RUN}" == "1" ]]; then
        log_line "[DRY-RUN] would open ${dev} as ${mapper}, then run: zpool create -m ${mountpoint} ${mapper} /dev/mapper/${mapper}"
        printf '[DRY-RUN] would open %s as %s, then create zpool %s mounted at %s\n' "$dev" "$mapper" "$mapper" "$mountpoint" >&2
        return 0
    fi
    printf '%s' "$passphrase" | cryptsetup open --batch-mode "$dev" "$mapper" - >>"$WARDEN_LOG_FILE" 2>&1
    if [[ ! -e "/dev/mapper/${mapper}" ]]; then
        log_line "  -> failed to open ${dev} as ${mapper} to create zpool"
        return 1
    fi
    run_cmd "create zpool ${mapper} on /dev/mapper/${mapper}, mounted at ${mountpoint}" -- zpool create -m "$mountpoint" "$mapper" "/dev/mapper/${mapper}"
}

# ensure_zfs_import_unit_template_installed — writes the shared
# per-device import unit template, backing up any previous version
# first. Idempotent: a no-op if the content is already identical.
ensure_zfs_import_unit_template_installed() {
    if [[ -f "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE" ]] && diff -q <(printf '%s' "$WARDEN_ZFS_IMPORT_UNIT_CONTENT") "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE" >/dev/null 2>&1; then
        log_line "UNIT: ${WARDEN_ZFS_IMPORT_UNIT_TEMPLATE} already up to date, skipping"
        return 0
    fi
    if [[ "${WARDEN_DRY_RUN}" == "1" ]]; then
        log_line "[DRY-RUN] would write ${WARDEN_ZFS_IMPORT_UNIT_TEMPLATE}"
        printf '[DRY-RUN] would write %s\n' "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE" >&2
        return 0
    fi
    local before after
    before="$(mktemp)"
    [[ -f "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE" ]] && cp -p "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE" "$before"
    [[ -f "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE" ]] && backup_file "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE" >/dev/null
    printf '%s' "$WARDEN_ZFS_IMPORT_UNIT_CONTENT" > "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE"
    after="$(mktemp)"
    cp -p "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE" "$after"
    log_diff "$WARDEN_ZFS_IMPORT_UNIT_TEMPLATE" "$before" "$after"
    rm -f "$before" "$after"
    run_cmd "reload systemd units" -- systemctl daemon-reload
}

# enable_zfs_import_unit <mapper> — installs the template if needed,
# then enables this device's import unit instance.
enable_zfs_import_unit() {
    local mapper="$1"
    ensure_zfs_import_unit_template_installed
    ensure_systemd_unit_enabled "warden-zfs-import@${mapper}.service"
}

# disable_zfs_import_unit <mapper> — for uninstall/forget; leaves the
# shared template file in place since other devices may still use it.
disable_zfs_import_unit() {
    local mapper="$1"
    run_cmd "disable and stop ZFS import unit for ${mapper}" -- systemctl disable --now "warden-zfs-import@${mapper}.service"
}

# is_zfs_pool_member <dev> — true if <dev>'s filesystem type (as seen
# by lsblk) is a ZFS pool member.
is_zfs_pool_member() {
    local dev="$1"
    [[ "$(lsblk -dno FSTYPE "$dev" 2>/dev/null)" == "zfs_member" ]]
}

# describe_zfs_pool_status <pool> — zpool health plus dataset mount
# state, for the status dashboard. Handles "not currently imported"
# explicitly rather than letting zpool/zfs's own error text leak
# through, since that's an expected, common state (e.g. before the
# device has unlocked at boot), not a fault.
describe_zfs_pool_status() {
    local pool="$1"
    if ! zpool list "$pool" >/dev/null 2>&1; then
        printf '(pool not currently imported)\n'
        return 0
    fi
    zpool status "$pool" 2>/dev/null | awk '/^[[:space:]]*pool:|^[[:space:]]*state:/'
    zfs list -H -o name,mounted,mountpoint "$pool" 2>/dev/null
    return 0
}
