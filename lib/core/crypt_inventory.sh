# shellcheck shell=bash
# lib/core/crypt_inventory.sh — read-only LUKS/crypttab/fstab inventory
#
# Shared by the status dashboard and the LUKS enrolment wizard: both
# need the same answer to "which crypto_LUKS devices exist, and which
# of them are already managed (in /etc/crypttab)?" -- this exact
# "wait, is this already managed?" confusion came up in practice, so
# there is exactly one implementation of the check, not two that could
# drift apart.

# luks_devices — one "<devpath> <uuid>" pair per line for every
# crypto_LUKS device currently visible to the kernel.
#
# Uses `lsblk --json` rather than raw/awk column parsing -- see
# candidate_format_devices in lib/features/luks_setup.sh for the exact
# empty-column parsing bug this avoids. Not reproducible here today
# (a real crypto_LUKS device's UUID is never actually empty, so the
# awk column-shift this pattern is prone to never triggered by
# accident), but fixed anyway rather than leaving the same fragile
# assumption in a second place.
luks_devices() {
    lsblk --json -o PATH,UUID,FSTYPE 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
for dev in data.get("blockdevices", []):
    if dev.get("fstype") == "crypto_LUKS":
        print(dev["path"], dev.get("uuid") or "")
'
}

# crypttab_mapper_for_uuid <uuid> — echoes the mapper name if <uuid> has
# a crypttab entry, empty otherwise. Never trusts a cached view: reads
# /etc/crypttab fresh.
crypttab_mapper_for_uuid() {
    local uuid="$1" crypttab="${WARDEN_CRYPTTAB:-/etc/crypttab}"
    [[ -f "$crypttab" ]] || return 0
    awk -v u="UUID=${uuid}" '$0 !~ /^#/ && $2 == u {print $1; exit}' "$crypttab"
}

# fstab_has_mapper <mapper> — true if /etc/fstab references this mapper device.
fstab_has_mapper() {
    local mapper="$1" fstab="${WARDEN_FSTAB:-/etc/fstab}"
    [[ -f "$fstab" ]] || return 1
    grep -qE "^[^#]*/dev/mapper/${mapper}(\s|$)" "$fstab"
}

# crypttab_mapper_names — every mapper name currently listed in
# /etc/crypttab, one per line. Used to suggest a naming convention and
# to avoid colliding with an existing name.
crypttab_mapper_names() {
    local crypttab="${WARDEN_CRYPTTAB:-/etc/crypttab}"
    [[ -f "$crypttab" ]] || return 0
    awk '$0 !~ /^#/ && NF {print $1}' "$crypttab"
}

# managed_luks_devices — "<devpath> <uuid> <mapper>" for crypto_LUKS
# devices that already have a crypttab entry. Excludes anything that is
# or backs root/boot/efi, same as the enrolment wizard's exclusion:
# Warden never touches root-drive bindings via a general-purpose menu.
managed_luks_devices() {
    local dev uuid mapper
    while read -r dev uuid; do
        [[ -n "$dev" ]] || continue
        mapper="$(crypttab_mapper_for_uuid "$uuid")"
        [[ -n "$mapper" ]] || continue
        guard_not_system_critical "$dev" || continue
        printf '%s %s %s\n' "$dev" "$uuid" "$mapper"
    done < <(luks_devices)
}
