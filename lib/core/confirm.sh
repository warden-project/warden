# shellcheck shell=bash
# lib/core/confirm.sh — typed-confirmation primitives
#
# Destructive operations must never be gated by a single-key y/n. This
# provides one generic "type this exact string back" primitive; callers
# decide what the expected string is (e.g. a UUID fragment for Danger
# Zone, per the wiki's confirmation-phrase design).

# confirm_typed_phrase <expected> <prompt_text>
# Returns 0 if the typed input matches exactly, 1 otherwise.
confirm_typed_phrase() {
    local expected="$1" prompt_text="$2"
    local typed

    if [[ "${WARDEN_NO_WHIPTAIL:-0}" == "1" ]] || [[ ! -t 0 ]]; then
        printf '%s\n> ' "$prompt_text" >&2
        IFS= read -r typed
    else
        typed="$(whiptail --inputbox "$prompt_text" 12 70 3>&1 1>&2 2>&3)" || return 1
    fi

    if [[ "$typed" == "$expected" ]]; then
        log_line "CONFIRM: typed phrase matched (prompt: ${prompt_text})"
        return 0
    fi
    log_line "CONFIRM: typed phrase did NOT match (prompt: ${prompt_text})"
    return 1
}

# uuid_fragment <uuid> — the first 8 characters (the segment before the
# first hyphen in a standard UUID). Short enough to type without
# friction, but only derivable by actually reading the UUID shown on
# screen at confirmation time -- unlike a fixed phrase, it can't be
# given from memory for the wrong device.
uuid_fragment() {
    printf '%s' "${1:0:8}"
}

# confirm_destructive_device_action <devpath> <identifier> <action_word>
#
# <identifier> is whatever uniquely names the device right now: its
# LUKS/filesystem UUID when it has one, or the device path itself for
# a blank device being formatted for the first time (which by
# definition has no UUID yet -- that's what luksFormat creates). Either
# way it must be the thing actually shown on screen, read fresh, not a
# value carried over from earlier in the session.
#
# The one path every destructive disk operation must go through:
#   1. Shows the current `lsblk -f` view so the person can visually
#      confirm the target immediately before acting.
#   2. Refuses by default if the device is or backs root/boot/efi,
#      requiring the full identifier typed back verbatim as a distinct,
#      harder override step (not the same bar as normal confirmation).
#   3. Either way, still requires the normal typed confirmation
#      ("<ACTION> <8-char identifier fragment>") before returning
#      success -- surviving the override is not itself sufficient.
#
# Returns 0 only if cleared to proceed.
confirm_destructive_device_action() {
    local dev="$1" identifier="$2" action="$3"
    local snapshot_file
    snapshot_file="$(mktemp)"
    lsblk_snapshot > "$snapshot_file"
    whiptail --title "Confirm target device" --scrolltext --textbox "$snapshot_file" 24 100
    rm -f "$snapshot_file"

    if ! guard_not_system_critical "$dev"; then
        whiptail --title "REFUSED: system-critical device" --msgbox "${dev} (${identifier}) is or backs this system's root filesystem, /boot, or /boot/efi.\n\nWarden refuses this by default." 14 78
        if ! confirm_typed_phrase "$identifier" "To override this refusal, type this back exactly:\n\n${identifier}"; then
            log_line "GUARD OVERRIDE: refused for ${dev} (${identifier}) -- override not confirmed"
            return 1
        fi
        log_line "GUARD OVERRIDE: override confirmed for ${dev} (${identifier})"
    fi

    local frag expected
    frag="$(uuid_fragment "$identifier")"
    expected="${action} ${frag}"
    if ! confirm_typed_phrase "$expected" "This will run: ${action} on ${dev} (${identifier}).\n\nTo confirm, type exactly:\n\n${expected}"; then
        log_line "CONFIRM: destructive action '${action}' on ${dev} (${identifier}) not confirmed"
        return 1
    fi
    return 0
}
