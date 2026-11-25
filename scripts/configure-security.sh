#!/usr/bin/env bash
set -Eeuo pipefail

_fail() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

_main() {
    export LC_ALL=C
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    [[ $EUID -eq 0 ]] || _fail 'Run with sudo from the dedicated VM console.'
    [[ $# -eq 1 && $1 == --dedicated-lab ]] || _fail 'Usage: configure-security.sh --dedicated-lab (VM console required).'
    command -v ufw >/dev/null || _fail 'Run install.sh first.'
    local _rule _rules _effective _backup _config=/etc/ssh/sshd_config.d/00-agent-app.conf
    # Refuse unrelated rules rather than silently deleting an existing policy.
    _rules=$(ufw show added) || _fail 'Cannot inspect existing firewall rules.'
    while IFS= read -r _rule; do
        [[ $_rule != ufw\ * || $_rule == 'ufw allow 20022/tcp' || $_rule == 'ufw allow 15034/tcp' ]] || \
            _fail "Existing firewall rule requires review: $_rule"
    done <<< "$_rules"
    [[ ! -L $_config ]] || _fail 'SSH drop-in must not be a symbolic link.'
    install -d -m 0755 /etc/ssh/sshd_config.d /run/sshd
    _backup=$(mktemp)
    if [[ -f $_config ]]; then
        cp -- "$_config" "$_backup"
    fi
    printf 'Port 20022\nPermitRootLogin no\n' > "$_config"
    chmod 0644 "$_config"
    if ! sshd -t || ! _effective=$(sshd -T) ||
        [[ $(awk '$1=="port" {print $2}' <<< "$_effective") != 20022 ]] ||
        [[ $(awk '$1=="permitrootlogin" {print $2}' <<< "$_effective") != no ]]; then
        if [[ -s $_backup ]]; then
            cp -- "$_backup" "$_config"
        else
            rm -- "$_config"
        fi
        rm -f -- "$_backup"
        _fail 'Conflicting SSH configuration; the managed drop-in was restored. No firewall rules were changed.'
    fi
    rm -- "$_backup"
    ufw allow 20022/tcp
    ufw allow 15034/tcp
    ufw default deny incoming
    ufw default allow outgoing
    ufw --force enable
    # Disable socket activation so sshd_config is the sole port configuration.
    systemctl disable --now ssh.socket 2>/dev/null || true
    systemctl enable ssh.service
    systemctl restart ssh.service
    ss -H -ltnp 'sport = :20022' | grep -q sshd || _fail 'sshd is not listening on TCP 20022.'
    [[ -z $(ss -H -ltn 'sport = :22') ]] || _fail 'A listener still exists on TCP 22.'
    ufw status verbose
    printf '[INFO] SSH:20022, PermitRootLogin:no, UFW:deny incoming with TCP 20022/15034 allowed.\n'
}

_main "$@"
