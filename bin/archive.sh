#!/usr/bin/env bash
set -Eeuo pipefail

_main() {
    export LC_ALL=C
    umask 0007
    local _logs=${AGENT_LOG_DIR:-/var/log/agent-app}
    local _archive=${AGENT_ARCHIVE_DIR:-/var/log/monitor/agent-app/archive}
    local _lock_fd _file _target _temporary
    if [[ ! -d $_logs || ! -w $_logs || ! -d $_archive || ! -w $_archive ]]; then
        printf '[WARNING] Log/archive directory missing or not writable.\n' >&2
        return 1
    fi
    exec {_lock_fd}>> "$_logs/.monitor.lock"
    flock -n "$_lock_fd" || return 0
    # Never move the active monitor log or the active application boot log.
    # Fractional mtime avoids find -mtime rounding an exact seven days to eight.
    while IFS= read -r -d '' _file; do
        _target=$_archive/$(basename -- "$_file").$(stat -c %Y -- "$_file").gz
        if [[ -e $_target ]]; then
            printf '[WARNING] Archive already exists: %s\n' "$_target" >&2
            continue
        fi
        _temporary=$(mktemp "$_archive/.archive.XXXXXX")
        if gzip -c -- "$_file" > "$_temporary" && mv -- "$_temporary" "$_target"; then
            rm -- "$_file"
            printf '[INFO] Archived: %s\n' "$_target"
        else
            rm -f -- "$_temporary"
            printf '[WARNING] Compression failed: %s\n' "$_file" >&2
            return 1
        fi
    done < <(find "$_logs" -maxdepth 1 -type f \( -name '*.log' -o -name 'monitor.log.[1-9]' \) \
        ! -name monitor.log ! -name boot.log -mmin +10080 -print0)
    find "$_archive" -maxdepth 1 -type f -name '*.gz' -mmin +43200 -print -delete
}

_main "$@"
