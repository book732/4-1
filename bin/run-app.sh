#!/usr/bin/env bash
set -Eeuo pipefail

_main() {
    [[ $EUID -ne 0 ]] || { printf '[ERROR] Root execution is forbidden.\n' >&2; return 1; }
    : "${AGENT_HOME:?AGENT_HOME must be set}"
    local _executable=${AGENT_EXECUTABLE:-$AGENT_HOME/agent_app.py}
    cd -- "$AGENT_HOME"
    if [[ $_executable == *.py ]]; then
        exec /usr/bin/python3 -u "$_executable"
    fi
    exec "$_executable"
}

_main "$@"
