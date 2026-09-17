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
luks_devices() {
    lsblk -no PATH,UUID,FSTYPE -rp 2>/dev/null | awk '$3=="crypto_LUKS"{print $1, $2}'
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
