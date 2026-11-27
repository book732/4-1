#!/usr/bin/env bash
set -Eeuo pipefail

_fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

_cleanup() {
    systemctl stop "$_unit" 2>/dev/null || true
    if [[ -f /run/systemd/system/$_unit ]]; then
        rm -- "/run/systemd/system/$_unit"
        systemctl daemon-reload
    fi
    # Preserve fixture files in /run for diagnosing a failed deployment check.
}

_main() {
    export LC_ALL=C
    [[ $EUID -eq 0 && $# -eq 1 ]] || _fail 'Usage: sudo bash tests/systemd.sh existing-non-root-user'
    local _user=$1 _primary _alternate _root _runtime _unit _pid _attempt _result _status
    [[ $(id -u "$_user") -ne 0 ]] || _fail 'A non-root test account is required.'
    _primary=$(id -gn "$_user")
    _alternate=$(id -nG "$_user" | tr ' ' '\n' | awk -v p="$_primary" '$0!=p {print; exit}')
    [[ -n $_alternate ]] || _fail 'The test account needs an existing supplementary group.'
    [[ -z $(ss -H -ltn 'sport = :15034') ]] || _fail 'TCP 15034 is occupied; no process was stopped.'
    _root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
    _runtime=$(mktemp -d /run/agent-app-regression.XXXXXX)
    _unit=agent-app-regression-${_runtime##*.}.service
    chmod 0755 "$_runtime"
    install -d -o "$_user" -g "$_primary" -m 0750 "$_runtime/app" "$_runtime/app/upload_files" \
        "$_runtime/app/api_keys" "$_runtime/logs"
    install -m 0644 "$_root/app/agent_app.py" "$_runtime/app/agent_app.py"
    printf 'agent_api_key_test\n' > "$_runtime/app/api_keys/t_secret.key"
    trap _cleanup EXIT
    # Keep the shipped sandbox settings; map only the account, paths, and launcher.
    sed -e "s/^User=agent-admin$/User=$_user/" \
        -e "s/^Group=agent-core$/Group=$_alternate/" \
        -e "s/^SupplementaryGroups=.*/SupplementaryGroups=$_primary $_alternate/" \
        -e "s|^WorkingDirectory=.*|WorkingDirectory=$_runtime/app|" \
        -e "s|^ExecStart=.*|ExecStart=/usr/bin/python3 -u $_runtime/app/agent_app.py|" \
        -e "s|^ReadWritePaths=.*|ReadWritePaths=$_runtime/app/upload_files $_runtime/logs|" \
        "$_root/config/agent-app.service" > "/run/systemd/system/$_unit"
    printf '\n[Service]\nEnvironment=AGENT_HOME=%s/app AGENT_PORT=15034 AGENT_UPLOAD_DIR=%s/app/upload_files AGENT_KEY_PATH=%s/app/api_keys/t_secret.key AGENT_LOG_DIR=%s/logs\n' \
        "$_runtime" "$_runtime" "$_runtime" "$_runtime" >> "/run/systemd/system/$_unit"
    systemctl daemon-reload
    systemctl start "$_unit"
    for ((_attempt=0; _attempt<50; _attempt++)); do
        if [[ -n $(ss -H -ltn 'sport = :15034') ]]; then
            break
        fi
        sleep 0.1
    done
    _pid=$(systemctl show -p MainPID --value "$_unit")
    printf 'systemd regression time: %s\nTest account: %s, primary group: %s\n' "$(date --iso-8601=seconds)" "$_user" "$_primary"
    journalctl -u "$_unit" --no-pager -o cat
    grep -E '^(Uid|Gid|Groups):' "/proc/$_pid/status" | sed 's/[[:blank:]]*$//'
    printf '\nRoot listener view:\n'
    ss -H -ltnp 'sport = :15034'
    printf '\nNon-root listener view:\n'
    runuser -u "$_user" -- ss -H -ltnp 'sport = :15034'
    if _result=$(runuser -u "$_user" -- env AGENT_HOME="$_runtime/app" AGENT_PORT=15034 \
        AGENT_LOG_DIR="$_runtime/logs" bash "$_root/bin/monitor.sh" 2>&1); then
        _status=0
    else
        _status=$?
    fi
    printf '\nMonitor exit: %s\n%s\n' "$_status" "$_result"
    [[ $_status == 0 ]] || _fail 'Non-root monitor could not verify the systemd application.'
    grep -Fq "PID:$_pid" <<< "$_result" || _fail 'Monitor selected a different PID.'
    [[ -s $_runtime/logs/monitor.log ]] || _fail 'Monitor did not write a sample.'
    cat "$_runtime/logs/monitor.log"
    printf '[PASS] Non-root monitor verifies the sandboxed systemd app and appends a sample.\n'
    _cleanup
    trap - EXIT
}

_main "$@"
