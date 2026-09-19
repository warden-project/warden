# shellcheck shell=bash
# lib/features/root_unlock.sh — menu 13: root-drive unlock (clevis-initramfs)
#
# See docs/future-work.md for the full design. This file starts with
# the pure, read-only safety-check primitives the wizard depends on --
# no mutation, no whiptail -- built and tested first, before any of the
# actual bind/initramfs-regeneration logic that touches boot-critical
# state.

# resolve_root_luks_device — the crypto_LUKS device backing the
# current root filesystem, walking up through any LVM layers, or
# empty if root isn't LUKS-encrypted at all. Never cached: resolved
# fresh every call, matching this project's device-resolution rule
# (see lib/core/device.sh).
#
# Confirmed on real hardware: `lsblk -no PKNAME <device>` does not
# reliably resolve a single device's parent in isolation (it depends
# on lsblk being asked to show the whole topology) -- this walks the
# full JSON tree instead, tracking every crypto_LUKS ancestor seen on
# the way down and returning the closest one to the target, if any.
resolve_root_luks_device() {
    local src target
    src="$(findmnt -no SOURCE / 2>/dev/null)"
    [[ -n "$src" ]] || return 0
    target="$(basename "$src")"

    lsblk --json -o NAME,FSTYPE 2>/dev/null | python3 -c '
import json, sys

def find_luks_ancestor(node, target, luks_stack):
    name = node.get("name")
    is_luks = node.get("fstype") == "crypto_LUKS"
    new_stack = luks_stack + [name] if is_luks else luks_stack
    if name == target:
        return new_stack[-1] if new_stack else None
    for child in node.get("children", []):
        result = find_luks_ancestor(child, target, new_stack)
        if result is not None:
            return result
    return None

data = json.load(sys.stdin)
target = sys.argv[1]
for dev in data.get("blockdevices", []):
    result = find_luks_ancestor(dev, target, [])
    if result:
        print("/dev/" + result)
        break
' "$target"
    return 0
}

# is_boot_separate_from_root — true if /boot is its own mountpoint,
# distinct from /.
#
# Confirmed on real hardware: Ubuntu's default encrypted-install
# layout keeps /boot as its own plain, unencrypted partition entirely
# outside the LUKS volume -- GRUB never decrypts anything itself, it
# just reads the kernel/initrd normally from plain /boot, and all
# decryption happens later, inside the already-loaded initramfs. An
# earlier version of this design assumed GRUB_ENABLE_CRYPTODISK needed
# checking; that's only relevant in the uncommon case where /boot
# itself lives inside the encrypted volume, which this check detects.
is_boot_separate_from_root() {
    local root_src boot_src
    root_src="$(findmnt -no SOURCE / 2>/dev/null)"
    boot_src="$(findmnt -no SOURCE /boot 2>/dev/null)"
    [[ -n "$boot_src" && "$boot_src" != "$root_src" ]]
}

# is_tpm2_present — true if a TPM2 device node exists.
is_tpm2_present() {
    [[ -e /dev/tpmrm0 || -e /dev/tpm0 ]]
}

# is_local_address <host> — true if <host> is loopback, or resolves to
# any address currently assigned to one of this machine's own network
# interfaces.
#
# Used to hard-block a same-host Tang dependency for root unlock: Tang
# runs as a systemd service, which can't start until the real root
# filesystem is already mounted, and root can't mount until it's
# unlocked -- a same-host Tang address can never work, regardless of
# whether it's technically reachable. Not a reachability question, a
# bootstrapping impossibility, so this is a hard block, not a warning.
is_local_address() {
    local host="$1"
    case "$host" in
        127.*|::1|localhost) return 0 ;;
    esac

    local resolved
    resolved="$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}')"
    [[ -n "$resolved" ]] || resolved="$host"

    # Re-check after resolution too: a hostname can resolve to loopback
    # (e.g. /etc/hosts mapping it to 127.0.0.1) even when the literal
    # input didn't look like loopback itself.
    case "$resolved" in
        127.*|::1) return 0 ;;
    esac

    local local_ip
    while IFS= read -r local_ip; do
        [[ -n "$local_ip" ]] || continue
        [[ "$local_ip" == "$resolved" ]] && return 0
    done < <(ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    return 1
}
