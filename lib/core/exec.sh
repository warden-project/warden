# shellcheck shell=bash
# lib/core/exec.sh — the single chokepoint every mutating command runs through
#
# Nothing in lib/features/* should call cryptsetup/clevis/systemctl/apt/etc
# directly. Everything routes through run_cmd so that dry-run and logging
# are structural guarantees, not something each wizard has to remember.

: "${WARDEN_DRY_RUN:=0}"

# run_cmd "<human description>" -- cmd arg1 arg2 ...
# Returns the command's exit status (0 in dry-run mode, without executing).
run_cmd() {
    local desc="$1"
    shift
    if [[ "$1" != "--" ]]; then
        echo "run_cmd: expected '--' before command, got '$1'" >&2
        return 2
    fi
    shift

    local display
    display="$(printf '%q ' "$@")"

    if [[ "${WARDEN_DRY_RUN}" == "1" ]]; then
        log_line "[DRY-RUN] ${desc}: ${display}"
        printf '[DRY-RUN] %s\n  $ %s\n' "$desc" "$display" >&2
        return 0
    fi

    log_line "RUN ${desc}: ${display}"
    local output status
    # Always redirect stdin from /dev/null: bin/warden itself normally
    # runs attached to a live, interactive terminal (whiptail needs
    # one), and without this every subprocess run here would inherit
    # that same live terminal as its own stdin. Found live: `clevis
    # luks unbind` (specifically for a tang-pinned slot; a tpm2 slot
    # never triggered it) hung indefinitely when run this way, because
    # something in its call chain attempts a stdin read that blocks
    # forever waiting for a keypress nobody is there to type -- but
    # returns instantly with a harmless "Nothing to read on input"
    # notice when stdin is already closed/EOF, as it always should be
    # for a command Warden runs on its own behalf. run_cmd is the one
    # chokepoint every mutating command goes through, so this closes
    # the risk everywhere at once rather than only at the one call site
    # that happened to surface it.
    output="$("$@" 2>&1 </dev/null)"
    status=$?
    log_line "  -> exit ${status}"
    if [[ -n "$output" ]]; then
        printf '%s\n' "$output" >> "$WARDEN_LOG_FILE"
    fi
    printf '%s\n' "$output"
    return "$status"
}
