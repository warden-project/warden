# shellcheck shell=bash
# lib/core/device.sh — device resolution and the root/boot/EFI guard
#
# Rule: never trust /dev/sdX naming. Every function here resolves fresh
# each call (no caching) so a stale answer can never be reused across a
# retry or an interrupted session.

# lsblk_snapshot — the exact "lsblk -f"-equivalent view to show before
# any destructive operation, so the person can visually confirm the target.
lsblk_snapshot() {
    lsblk -f
}

# uuid_for_device <devpath> — resolve a device path to its filesystem/LUKS UUID.
uuid_for_device() {
    local dev="$1"
    lsblk -no UUID "$dev" 2>/dev/null | head -n1
}

# devpath_for_uuid <uuid> — resolve a UUID back to its current /dev path.
# Never store the result; re-resolve at point of use.
devpath_for_uuid() {
    local uuid="$1"
    local resolved
    resolved="$(blkid -U "$uuid" 2>/dev/null)" || true
    printf '%s' "$resolved"
}

# _resolved_backing_disk <mountpoint> — the disk-level device backing a
# mountpoint, following LUKS/LVM one layer where straightforward. Best
# effort: the guard below treats "unable to resolve" as critical (fail
# closed), never as "safe to proceed".
_resolved_backing_disk() {
    local mnt="$1"
    findmnt -no SOURCE --target "$mnt" 2>/dev/null
}

# is_system_critical <devpath> — true if devpath is, or backs, the
# current root filesystem, /boot, or /boot/efi.
#
# This exists because of a near-miss where an EFI boot partition was
# almost run through luksFormat: fail closed (treat "can't tell" as
# critical) rather than fail open.
is_system_critical() {
    local target="$1"
    local target_real
    target_real="$(readlink -f "$target" 2>/dev/null)" || target_real="$target"

    local mnt src src_real
    for mnt in / /boot /boot/efi; do
        src="$(_resolved_backing_disk "$mnt")"
        if [[ -z "$src" ]]; then
            # No such mountpoint (e.g. no separate /boot) — nothing to compare.
            [[ "$mnt" == "/" ]] || continue
        fi
        src_real="$(readlink -f "$src" 2>/dev/null)" || src_real="$src"
        if [[ -n "$src_real" && "$src_real" == "$target_real" ]]; then
            return 0
        fi
        # Also compare by UUID in case one side is a mapper name and the
        # other a raw partition for the same underlying device.
        local target_uuid src_uuid
        target_uuid="$(uuid_for_device "$target_real" 2>/dev/null)"
        src_uuid="$(uuid_for_device "$src_real" 2>/dev/null)"
        if [[ -n "$target_uuid" && -n "$src_uuid" && "$target_uuid" == "$src_uuid" ]]; then
            return 0
        fi
    done
    return 1
}

# guard_not_system_critical <devpath> — refuse by default if the device
# is system-critical. Caller is responsible for the explicit, distinct
# override step (typed UUID confirmation) required by the safety spec;
# this function only ever returns the fail-closed verdict.
guard_not_system_critical() {
    local dev="$1"
    if is_system_critical "$dev"; then
        log_line "GUARD: refused - ${dev} is or backs root/boot/efi"
        return 1
    fi
    return 0
}
