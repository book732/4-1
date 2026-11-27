#!/usr/bin/env bash
set -Eeuo pipefail

_fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

_cleanup() {
    kill -- "-$_child" 2>/dev/null || true
    wait "$_child" 2>/dev/null || true
}

_main() {
    export LC_ALL=C
    [[ $EUID -ne 0 && $# -eq 1 && -f $1 ]] || _fail 'Usage: bash tests/original.sh /path/to/original-binary (non-root)'
    local _source _name _root _runtime _child _attempt _stage
    _source=$(realpath -- "$1")
    _name=${_source##*/}
    [[ $_name == agent-app-linux-x86 || $_name == agent-app-linux-arm64 ]] || _fail 'Keep the original binary filename.'
    [[ -z $(ss -H -ltn 'sport = :15034') ]] || _fail 'TCP 15034 is occupied; no process was stopped.'
    _root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
    mkdir -p "$_root/.test-runtime"
    _runtime=$(mktemp -d "$_root/.test-runtime/original.XXXXXX")
    export AGENT_HOME=$_runtime/app AGENT_PORT=15034
    export AGENT_UPLOAD_DIR=$AGENT_HOME/upload_files AGENT_KEY_PATH=$AGENT_HOME/api_keys/t_secret.key
    export AGENT_LOG_DIR=$_runtime/logs AGENT_EXECUTABLE=$AGENT_HOME/$_name
    mkdir -p "$AGENT_UPLOAD_DIR" "$AGENT_HOME/api_keys" "$AGENT_LOG_DIR"
    cp -- "$_source" "$AGENT_EXECUTABLE"
    chmod 0750 "$AGENT_EXECUTABLE"
    printf 'agent_api_key_test\n' > "$AGENT_KEY_PATH"
    cp -- "$AGENT_KEY_PATH" "$AGENT_HOME/api_keys/secret.key"
    : > "$_runtime/boot.log"
    # Exercise the shipped launcher with the PDF-style file path still configured.
    setsid bash "$_root/bin/run-app.sh" > "$_runtime/boot.log" 2>&1 &
    _child=$!
    trap _cleanup EXIT
    for ((_attempt=0; _attempt<100; _attempt++)); do
        if grep -q '^Agent READY$' "$_runtime/boot.log"; then
            break
        fi
        kill -0 "$_child" 2>/dev/null || break
        sleep 0.1
    done
    cat "$_runtime/boot.log"
    for _stage in 1 2 3 4 5; do
        grep -Eq "\[$_stage/5\].*\[OK\]" "$_runtime/boot.log" || _fail "Original boot stage $_stage did not pass."
    done
    grep -q '^Agent READY$' "$_runtime/boot.log" || _fail 'Original app did not become ready.'
    bash "$_root/bin/monitor.sh"
    [[ -s $AGENT_LOG_DIR/monitor.log ]] || _fail 'No original-app monitoring sample was written.'
    printf '[PASS] Original app passes five boot checks, READY, owned port, and monitoring.\n'
    printf '[INFO] Isolated artifacts: %s\n' "$_runtime"
    _cleanup
    trap - EXIT
}

_main "$@"
