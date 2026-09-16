# shellcheck shell=bash
# lib/core/log.sh — session logging
#
# Every Warden session writes one timestamped log file capturing every
# command considered, whether it ran (dry-run vs real), and its output,
# so a session can be reconstructed and audited afterwards.

: "${WARDEN_LOG_DIR:=/var/log/warden}"

WARDEN_LOG_FILE=""

log_init() {
    mkdir -p "$WARDEN_LOG_DIR"
    chmod 700 "$WARDEN_LOG_DIR"
    local ts
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    WARDEN_LOG_FILE="${WARDEN_LOG_DIR}/warden-${ts}-$$.log"
    : > "$WARDEN_LOG_FILE"
    chmod 600 "$WARDEN_LOG_FILE"
    log_line "session started (pid $$, user $(id -un), dry_run=${WARDEN_DRY_RUN:-0})"
}

log_line() {
    local msg="$1"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '[%s] %s\n' "$ts" "$msg" >> "$WARDEN_LOG_FILE"
}

# log_diff <label> <before_file> <after_file>
# Records a unified diff between two files (e.g. crypttab before/after a patch).
log_diff() {
    local label="$1" before="$2" after="$3"
    {
        printf -- '--- diff: %s ---\n' "$label"
        diff -u "$before" "$after" || true
        printf -- '--- end diff: %s ---\n' "$label"
    } >> "$WARDEN_LOG_FILE"
}
