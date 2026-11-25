#!/usr/bin/env bash
set -Eeuo pipefail

_fail() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

_main() {
    export LC_ALL=C
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    [[ $EUID -eq 0 ]] || _fail 'Run this installer with sudo on a dedicated Ubuntu lab VM.'
    [[ -d /run/systemd/system ]] || _fail 'A booted systemd Linux environment is required.'
    local _source _name _root _user _directory _existing _attempt _status
    _root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
    if [[ $# -eq 1 && $1 == --demo ]]; then
        _source=$_root/app/agent_app.py
        _name=agent_app.py
        printf '[WARNING] Installing the verification replacement, not the original assignment app.\n'
    elif [[ $# -eq 2 && $1 == --app && $2 == /* && -f $2 ]]; then
        _source=$(realpath -- "$2")
        _name=$(basename -- "$_source")
    else
        _fail 'Usage: install.sh --app /absolute/path/to/provided-app OR install.sh --demo'
    fi
    [[ $_name =~ ^[a-zA-Z0-9_.-]+$ ]] || _fail 'Unsupported application filename.'
    [[ $(uname -s) == Linux ]] || _fail 'Linux is required.'
    # Do not reset an existing firewall or modify SSH as part of file installation.
    apt-get update
    apt-get install -y python3 procps iproute2 acl cron sudo ufw openssh-server util-linux gawk gzip
    for _directory in /opt/agent-app /opt/agent-app/bin /opt/agent-app/api_keys \
        /opt/agent-app/upload_files /var/log/agent-app /var/log/monitor \
        /var/log/monitor/agent-app /var/log/monitor/agent-app/archive; do
        [[ ! -L $_directory ]] || _fail "Refusing a symbolic link: $_directory"
    done
    getent group agent-common >/dev/null || groupadd agent-common
    getent group agent-core >/dev/null || groupadd agent-core
    for _user in agent-admin agent-dev agent-test; do
        if ! id "$_user" >/dev/null 2>&1; then
            useradd --create-home --shell /bin/bash "$_user"
        fi
        [[ $(id -u "$_user") -ne 0 ]] || _fail "Account must not be root: $_user"
        usermod -aG agent-common "$_user"
    done
    usermod -aG agent-core agent-admin
    usermod -aG agent-core agent-dev
    [[ " $(id -nG agent-test) " != *' agent-core '* ]] || _fail 'agent-test already belongs to agent-core; resolve this policy conflict first.'
    install -d -o root -g agent-common -m 2750 /opt/agent-app
    install -d -o root -g agent-core -m 2750 /opt/agent-app/bin
    install -d -o agent-admin -g agent-common -m 2770 /opt/agent-app/upload_files
    for _directory in /opt/agent-app/api_keys /var/log/agent-app; do
        install -d -o agent-admin -g agent-core -m 2770 "$_directory"
    done
    for _directory in /opt/agent-app/upload_files /opt/agent-app/api_keys /var/log/agent-app; do
        setfacl -b -- "$_directory"
        setfacl -k -- "$_directory"
        setfacl -m u::rwx,g::rwx,m::rwx,o::---,d:u::rwx,d:g::rwx,d:m::rwx,d:o::--- -- "$_directory"
    done
    install -d -o root -g agent-core -m 0750 /var/log/monitor /var/log/monitor/agent-app
    install -d -o agent-admin -g agent-core -m 2770 /var/log/monitor/agent-app/archive
    setfacl -m d:u::rwx,d:g::rwx,d:m::rwx,d:o::--- /var/log/monitor/agent-app/archive
    for _name in monitor.sh report.sh archive.sh; do
        install -o agent-dev -g agent-core -m 0750 "$_root/bin/$_name" "/opt/agent-app/bin/$_name"
    done
    install -o root -g agent-core -m 0750 "$_root/bin/run-app.sh" /opt/agent-app/bin/run-app.sh
    _name=$(basename -- "$_source")
    if [[ $_name == *.py ]]; then
        install -o root -g agent-core -m 0640 "$_source" "/opt/agent-app/$_name"
    else
        install -o root -g agent-core -m 0750 "$_source" "/opt/agent-app/$_name"
    fi
    if [[ -e /opt/agent-app/api_keys/t_secret.key ]]; then
        [[ ! -L /opt/agent-app/api_keys/t_secret.key ]] || _fail 'Key file must not be a symbolic link.'
        cmp -s /opt/agent-app/api_keys/t_secret.key <(printf 'agent_api_key_test\n') || _fail 'Existing key differs; it was not overwritten.'
    else
        printf 'agent_api_key_test\n' > /opt/agent-app/api_keys/t_secret.key
    fi
    chown agent-admin:agent-core /opt/agent-app/api_keys/t_secret.key
    chmod 0660 /opt/agent-app/api_keys/t_secret.key
    install -o root -g root -m 0644 "$_root/config/agent-app.env" /etc/agent-app.env
    sed -i '/^export AGENT_EXECUTABLE=/d' /etc/agent-app.env
    printf 'export AGENT_EXECUTABLE=/opt/agent-app/%s\n' "$_name" >> /etc/agent-app.env
    install -o root -g root -m 0644 "$_root/config/agent-app.service" /etc/systemd/system/agent-app.service
    printf 'agent-admin ALL=(root) NOPASSWD: /usr/sbin/ufw status\n' > /etc/sudoers.d/agent-app-firewall
    chmod 0440 /etc/sudoers.d/agent-app-firewall
    visudo -cf /etc/sudoers.d/agent-app-firewall
    # Preserve unrelated entries when the installer is run again.
    _existing=$(crontab -u agent-admin -l 2>/dev/null || true)
    {
        printf '%s\n' "$_existing" | sed '/ # agent-app-monitor$/d; / # agent-app-archive$/d'
        printf '%s\n' '* * * * * /bin/bash -c '\''. /etc/agent-app.env; /opt/agent-app/bin/monitor.sh 2>&1 | /usr/bin/logger -t agent-monitor'\'' # agent-app-monitor'
        printf '%s\n' '15 3 * * * /bin/bash -c '\''. /etc/agent-app.env; /opt/agent-app/bin/archive.sh 2>&1 | /usr/bin/logger -t agent-archive'\'' # agent-app-archive'
    } | crontab -u agent-admin -
    systemctl daemon-reload
    systemctl enable --now cron.service
    systemctl enable agent-app.service
    systemctl restart agent-app.service
    for ((_attempt=0; _attempt<30; _attempt++)); do
        if _status=$(runuser -u agent-admin -- /bin/bash -c '. /etc/agent-app.env; exec "$AGENT_HOME/bin/monitor.sh"' 2>&1); then
            printf '%s\n' "$_status"
            printf '[INFO] Installation complete. Configure SSH/UFW separately, then collect evidence.\n'
            printf '[INFO] New accounts are password-locked. Provision agent-admin SSH keys through the VM console.\n'
            return 0
        fi
        sleep 0.5
    done
    printf '%s\n' "$_status" >&2
    journalctl -u agent-app.service -n 30 --no-pager >&2
    _fail 'Application did not become healthy after installation.'
}

_main "$@"
