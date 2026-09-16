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
    output="$("$@" 2>&1)"
    status=$?
    log_line "  -> exit ${status}"
    if [[ -n "$output" ]]; then
        printf '%s\n' "$output" >> "$WARDEN_LOG_FILE"
    fi
    printf '%s\n' "$output"
    return "$status"
}
