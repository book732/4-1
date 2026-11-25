#!/usr/bin/env bash
set -Eeuo pipefail

_fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

_assert_access() {
    local _user=$1 _path=$2 _allowed=$3
    if runuser -u "$_user" -- test -r "$_path" &&
        runuser -u "$_user" -- test -w "$_path" &&
        runuser -u "$_user" -- test -x "$_path"; then
        [[ $_allowed == yes ]] || _fail "$_user unexpectedly has access to $_path"
    else
        [[ $_allowed == no ]] || _fail "$_user lacks required access to $_path"
        if runuser -u "$_user" -- test -x "$_path"; then
            _fail "$_user can traverse restricted directory $_path"
        fi
    fi
    printf '[PASS] %s access=%s %s\n' "$_user" "$_allowed" "$_path"
}

_collect() {
    local _user _directory _ssh _boot _invocation _before _after _attempt _probe _rules _rule
    printf 'Evidence time: %s\n' "$(date --iso-8601=seconds)"
    uname -a
    cat /etc/os-release
    printf '\n=== SSH effective configuration and listeners ===\n'
    _ssh=$(sshd -T)
    printf '%s\n' "$_ssh" | awk '$1=="port" || $1=="permitrootlogin"'
    [[ $(awk '$1=="port" {print $2}' <<< "$_ssh") == 20022 ]] || _fail 'SSH port differs from 20022.'
    [[ $(awk '$1=="permitrootlogin" {print $2}' <<< "$_ssh") == no ]] || _fail 'Root SSH login is permitted.'
    ss -ltnp
    ss -H -ltnp 'sport = :20022' | grep -q sshd || _fail 'SSH listener missing.'
    [[ -z $(ss -H -ltn 'sport = :22') ]] || _fail 'TCP 22 still listens.'

    printf '\n=== UFW ===\n'
    ufw status verbose
    ufw status | grep -q '^Status: active$' || _fail 'UFW is inactive.'
    ufw status verbose | grep -q 'Default: deny (incoming)' || _fail 'Inbound default is not deny.'
    _rules=$(ufw show added)
    printf '%s\n' "$_rules"
    grep -qx 'ufw allow 20022/tcp' <<< "$_rules" || _fail 'SSH firewall rule missing.'
    grep -qx 'ufw allow 15034/tcp' <<< "$_rules" || _fail 'App firewall rule missing.'
    while IFS= read -r _rule; do
        [[ $_rule != ufw\ * || $_rule == 'ufw allow 20022/tcp' || $_rule == 'ufw allow 15034/tcp' ]] || _fail "Unexpected UFW rule: $_rule"
    done <<< "$_rules"

    printf '\n=== Accounts, groups, directories, ACL ===\n'
    for _user in agent-admin agent-dev agent-test; do
        id "$_user"
        [[ " $(id -nG "$_user") " == *' agent-common '* ]] || _fail 'agent-common membership missing.'
    done
    for _user in agent-admin agent-dev; do
        [[ " $(id -nG "$_user") " == *' agent-core '* ]] || _fail 'agent-core membership missing.'
    done
    [[ " $(id -nG agent-test) " != *' agent-core '* ]] || _fail 'QA has core membership.'
    for _directory in "$AGENT_UPLOAD_DIR" "$AGENT_HOME/api_keys" "$AGENT_LOG_DIR"; do
        ls -ld "$_directory"
        getfacl -p "$_directory"
        for _user in agent-admin agent-dev agent-test; do
            if [[ $_directory == "$AGENT_UPLOAD_DIR" || $_user != agent-test ]]; then
                _assert_access "$_user" "$_directory" yes
            else
                _assert_access "$_user" "$_directory" no
            fi
        done
    done
    [[ $(stat -c '%U:%G:%a' "$AGENT_HOME/bin/monitor.sh") == agent-dev:agent-core:750 ]] || _fail 'monitor.sh ownership/mode differs.'
    stat -c '%U:%G:%a %n' "$AGENT_HOME/bin/monitor.sh" "$AGENT_KEY_PATH"
    _probe=$AGENT_UPLOAD_DIR/.acl-evidence-$$
    runuser -u agent-dev -- /bin/bash -c 'umask 0022; : > "$1"' _ "$_probe"
    for _user in agent-admin agent-test; do
        runuser -u "$_user" -- test -w "$_probe" || { rm -f -- "$_probe"; _fail 'Default ACL did not preserve shared file writes.'; }
    done
    getfacl -p "$_probe"
    rm -- "$_probe"

    printf '\n=== Application environment and current boot ===\n'
    cat /etc/agent-app.env
    systemctl is-active agent-app.service
    _invocation=$(systemctl show -p InvocationID --value agent-app.service)
    _boot=$(journalctl "_SYSTEMD_INVOCATION_ID=$_invocation" --no-pager -o cat)
    printf '%s\n' "$_boot"
    for _attempt in 1 2 3 4 5; do
        grep -Eq "\[$_attempt/5\].*\[OK\]" <<< "$_boot" || _fail "Boot stage $_attempt missing."
    done
    grep -q 'Agent READY' <<< "$_boot" || _fail 'Agent READY missing.'
    ss -H -ltn 'sport = :15034' | grep -q '0.0.0.0:15034' || _fail 'IPv4 wildcard app listener missing.'

    printf '\n=== Manual monitor execution as agent-admin ===\n'
    runuser -u agent-admin -- /bin/bash -c '. /etc/agent-app.env; exec "$AGENT_HOME/bin/monitor.sh"'
    tail -n 5 "$AGENT_LOG_DIR/monitor.log"
    printf '\n=== agent-admin crontab and automatic execution ===\n'
    crontab -u agent-admin -l
    crontab -u agent-admin -l | grep -q '^\* \* \* \* \* .* # agent-app-monitor$' || _fail 'Minute cron entry missing.'
    systemctl is-active cron.service
    _before=$(tail -n 1 "$AGENT_LOG_DIR/monitor.log")
    # Poll through a minute boundary without manually invoking the monitor again.
    for ((_attempt=0; _attempt<26; _attempt++)); do
        sleep 3
        _after=$(tail -n 1 "$AGENT_LOG_DIR/monitor.log")
        if [[ $_after != "$_before" ]]; then
            printf '[PASS] Cron-only new sample recorded (rotation-safe).\nBefore: %s\nAfter: %s\n' "$_before" "$_after"
            tail -n 3 "$AGENT_LOG_DIR/monitor.log"
            printf '\nALL DEPLOYMENT CHECKS PASSED\n'
            return 0
        fi
    done
    _fail 'No automatic cron sample arrived within 78 seconds.'
}

_main() {
    export LC_ALL=C
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    [[ $EUID -eq 0 ]] || _fail 'Run with sudo after installing on the dedicated VM.'
    source /etc/agent-app.env
    local _output=${1:-/var/log/agent-app/deployment-evidence.txt}
    umask 0027
    _collect 2>&1 | tee "$_output"
}

_main "$@"
