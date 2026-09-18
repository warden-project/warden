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

# uuid_for_device <devpath> — resolve a device path to its own
# filesystem/LUKS UUID.
#
# Must pass -d (no-deps): confirmed on real hardware that plain
# `lsblk -no UUID <disk>` on a disk with partitions lists the whole
# descendant tree, in an order that puts a *child's* UUID first --
# e.g. for a disk holding an LVM root, `lsblk -no UUID /dev/vda` (no
# -d) returned the root logical volume's filesystem UUID, not vda's
# own (correctly empty, since a partitioned disk has none). Without
# -d this silently made the whole-disk device (a valid, listed format
# candidate) look identical to the root filesystem to any UUID-based
# comparison, including the root/boot/efi guard.
uuid_for_device() {
    local dev="$1"
    lsblk -dno UUID "$dev" 2>/dev/null | head -n1
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

# is_system_critical <devpath> — true if devpath IS, or BACKS (anywhere
# in its full descendant chain -- partition, LVM PV, LV, dm alias...),
# the current root filesystem, /boot, or /boot/efi.
#
# This exists because of a near-miss where an EFI boot partition was
# almost run through luksFormat: fail closed (treat "can't tell" as
# critical) rather than fail open.
#
# Confirmed on real hardware: an earlier version of this check only
# compared devpath directly against each mountpoint's *immediate*
# backing device, which correctly caught e.g. the EFI partition itself
# but completely missed the *whole disk* device that holds it -- a
# disk with a partition table is never itself equal (by path or UUID)
# to any of its own partitions, so `/dev/vda` (holding root/boot/efi
# across vda1/vda2/vda3->LVM) was not flagged as critical even though
# formatting it destroys the partition table and everything on it.
# Fixed by checking whether the critical device appears anywhere in
# devpath's full descendant subtree (via `lsblk -rno PATH`, which
# walks through LVM/dm layers), not just at devpath itself.
is_system_critical() {
    local target="$1"
    local target_real
    target_real="$(readlink -f "$target" 2>/dev/null)" || target_real="$target"

    local -a subtree=()
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && subtree+=("$p")
    done < <(lsblk -rno PATH "$target_real" 2>/dev/null)
    subtree+=("$target_real")

    local mnt src src_real
    for mnt in / /boot /boot/efi; do
        src="$(_resolved_backing_disk "$mnt")"
        if [[ -z "$src" ]]; then
            # No such mountpoint (e.g. no separate /boot) — nothing to compare.
            [[ "$mnt" == "/" ]] || continue
        fi
        src_real="$(readlink -f "$src" 2>/dev/null)" || src_real="$src"

        local p_real
        for p in "${subtree[@]}"; do
            p_real="$(readlink -f "$p" 2>/dev/null)" || p_real="$p"
            if [[ -n "$p_real" && -n "$src_real" && "$p_real" == "$src_real" ]]; then
                return 0
            fi
        done

        # Also compare by UUID in case lsblk's tree enumeration doesn't
        # cover some layer (e.g. a mapper name reached a different way).
        local src_uuid
        src_uuid="$(uuid_for_device "$src_real" 2>/dev/null)"
        if [[ -n "$src_uuid" ]]; then
            local p_uuid
            for p in "${subtree[@]}"; do
                p_uuid="$(uuid_for_device "$p" 2>/dev/null)"
                if [[ -n "$p_uuid" && "$p_uuid" == "$src_uuid" ]]; then
                    return 0
                fi
            done
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
