# shellcheck shell=bash
# lib/core/backup.sh — backup-before-edit and minimal/targeted file patching
#
# Never regenerate crypttab/fstab wholesale: unrelated existing entries
# must never be touched or reordered. Always back up first.

: "${WARDEN_BACKUP_DIR:=/var/backups/warden}"

# backup_file <path> — copy path to a timestamped backup, return its path.
backup_file() {
    local path="$1"
    mkdir -p "$WARDEN_BACKUP_DIR"
    chmod 700 "$WARDEN_BACKUP_DIR"
    local ts base dest
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    base="$(basename "$path")"
    dest="${WARDEN_BACKUP_DIR}/${base}.${ts}.bak"
    cp -p "$path" "$dest"
    log_line "BACKUP: ${path} -> ${dest}"
    printf '%s' "$dest"
}

# append_line_if_missing <file> <line>
# Backs up first, then appends the line only if not already present
# verbatim. Idempotent: safe to call on every run.
append_line_if_missing() {
    local file="$1" line="$2"
    if grep -qxF "$line" "$file" 2>/dev/null; then
        log_line "PATCH: line already present in ${file}, skipping: ${line}"
        return 0
    fi
    local backup before after
    before="$(mktemp)"
    cp -p "$file" "$before"
    backup="$(backup_file "$file")"
    printf '%s\n' "$line" >> "$file"
    after="$(mktemp)"
    cp -p "$file" "$after"
    log_diff "${file} (backup: ${backup})" "$before" "$after"
    rm -f "$before" "$after"
}
