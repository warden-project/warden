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
