#!/usr/bin/env bash
set -Eeuo pipefail

_fail() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

_find_pid() {
    local _candidate _argument _found=1
    local -a _arguments
    # Compare complete argv tokens instead of matching a substring in ps output.
    while IFS= read -r _candidate; do
        [[ -r /proc/$_candidate/cmdline ]] || continue
        _arguments=()
        mapfile -d '' -t _arguments < "/proc/$_candidate/cmdline" 2>/dev/null || continue
        for _argument in "${_arguments[@]}"; do
            if [[ $_argument == "$_executable" ]]; then
                printf '%s\n' "$_candidate"
                _found=0
                break
            fi
        done
    done < <(pgrep -u "$(id -u)" -f -- "${_executable##*/}" || true)
    return "$_found"
}

_health_check() {
    local _listeners _candidates _candidate
    _candidates=$(_find_pid) || _fail "Application process not found: $_executable"
    _pid=${_candidates%%$'\n'*}
    _listeners=$(ss -H -ltnp "sport = :$AGENT_PORT") || _fail 'Cannot inspect TCP listeners.'
    # Frozen Python apps may have a launcher and a child with the same argv.
    while IFS= read -r _candidate; do
        if [[ $_listeners == *"pid=$_candidate,"* ]]; then
            _pid=$_candidate
            printf '[OK] Process PID:%s\n' "$_pid"
            printf '[OK] TCP %s LISTEN, owned by PID:%s\n' "$AGENT_PORT" "$_pid"
            return 0
        fi
    done <<< "$_candidates"
    _fail "TCP $AGENT_PORT is not owned by application PID $_pid (or another matching worker)."
}

_check_firewall() {
    local _status
    if command -v ufw >/dev/null 2>&1; then
        if (( EUID == 0 )); then
            _status=$(ufw status 2>/dev/null) || _status=unknown
        else
            _status=$(sudo -n /usr/sbin/ufw status 2>/dev/null) || _status=unknown
        fi
        if [[ $_status == *'Status: active'* ]]; then
            printf '[OK] UFW active\n'
        elif [[ $_status == *'Status: inactive'* ]]; then
            printf '[WARNING] UFW inactive\n'
        else
            printf '[WARNING] Cannot verify UFW status (permission or service error).\n'
        fi
    elif command -v firewall-cmd >/dev/null 2>&1; then
        if firewall-cmd --state >/dev/null 2>&1; then
            printf '[OK] firewalld active\n'
        else
            printf '[WARNING] firewalld inactive or inaccessible\n'
        fi
    else
        printf '[WARNING] No supported firewall found\n'
    fi
}

_cpu_snapshot() {
    # Guest times are already included in user/nice; count only the first eight fields.
    awk '/^cpu / {for (i=2;i<=9;i++) total+=$i; printf "%.0f %.0f\n", total, $5+$6; exit}' /proc/stat
}

_collect_resources() {
    local _total_before _idle_before _total_after _idle_after
    read -r _total_before _idle_before < <(_cpu_snapshot)
    sleep 1
    read -r _total_after _idle_after < <(_cpu_snapshot)
    _cpu=$(awk -v t="$((_total_after - _total_before))" -v i="$((_idle_after - _idle_before))" \
        'BEGIN {if (t<=0 || i<0 || i>t) exit 1; printf "%.1f", 100*(t-i)/t}') || _fail 'Invalid CPU sample.'
    _mem=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2; found=1}
        END {if (!found || t<=0) exit 1; printf "%.1f", 100*(t-a)/t}' /proc/meminfo) || _fail 'Invalid memory sample.'
    _disk=$(df -P / | awk 'NR==2 {gsub(/%/, "", $5); print $5}')
    [[ $_disk =~ ^[0-9]+$ ]] || _fail 'Invalid root filesystem usage.'
    printf 'CPU Usage: %s%%\nMEM Usage: %s%%\nDISK Used: %s%%\n' "$_cpu" "$_mem" "$_disk"
    _warn_thresholds
}

_warn_thresholds() {
    local _metric _value _threshold
    while read -r _metric _value _threshold; do
        if awk -v v="$_value" -v t="$_threshold" 'BEGIN {exit !(v>t)}'; then
            printf '[WARNING] %s threshold exceeded (%s%% > %s%%)\n' "$_metric" "$_value" "$_threshold"
        fi
    done <<< "CPU $_cpu 20
MEM $_mem 10
DISK_USED $_disk 80"
}

_append_log() {
    local _line _size=0 _index
    printf -v _line '[%s] PID:%s CPU:%s%% MEM:%s%% DISK_USED:%s%%' \
        "$(date '+%F %T')" "$_pid" "$_cpu" "$_mem" "$_disk"
    [[ ! -e $_log || ( -f $_log && ! -L $_log ) ]] || _fail 'Log must be a regular file.'
    if [[ -f $_log ]]; then
        _size=$(stat -c %s -- "$_log")
    fi
    # Ten files total: the current file and nine bounded backups.
    if (( _size + ${#_line} + 1 > 10485760 )); then
        rm -f -- "$_log.9"
        for (( _index=8; _index>=1; _index-- )); do
            [[ ! -e $_log.$_index ]] || mv -f -- "$_log.$_index" "$_log.$((_index + 1))"
        done
        mv -- "$_log" "$_log.1"
    fi
    printf '%s\n' "$_line" >> "$_log"
    printf '[INFO] Log appended: %s\n' "$_log"
}

_main() {
    export LC_ALL=C
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    umask 0007
    : "${AGENT_HOME:?AGENT_HOME must be set}"
    : "${AGENT_PORT:=15034}"
    : "${AGENT_LOG_DIR:=/var/log/agent-app}"
    local _executable=${AGENT_EXECUTABLE:-$AGENT_HOME/agent_app.py}
    local _log=$AGENT_LOG_DIR/monitor.log _lock_fd _pid _cpu _mem _disk
    [[ $AGENT_HOME == /* && $_executable == /* && $AGENT_LOG_DIR == /* ]] || _fail 'Absolute paths are required.'
    [[ $AGENT_PORT == 15034 ]] || _fail 'AGENT_PORT must be 15034.'
    [[ -d $AGENT_LOG_DIR && -w $AGENT_LOG_DIR ]] || _fail "Log directory is not writable: $AGENT_LOG_DIR"
    exec {_lock_fd}>> "$AGENT_LOG_DIR/.monitor.lock"
    if ! flock -n "$_lock_fd"; then
        printf '[INFO] Another monitoring or retention run holds the lock.\n'
        return 0
    fi
    printf '====== SYSTEM MONITOR RESULT ======\n'
    _health_check
    _check_firewall
    _collect_resources
    # Reject a process that disappeared while the one-second CPU sample was taken.
    kill -0 "$_pid" 2>/dev/null || _fail 'Application exited during sampling.'
    _append_log
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    _main "$@"
fi
