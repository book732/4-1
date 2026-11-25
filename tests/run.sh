#!/usr/bin/env bash
set -Eeuo pipefail

_fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

_pass() {
    _passed=$((_passed + 1))
    printf '[PASS] %s\n' "$*"
}

_expect_exit() {
    local _expected=$1 _status
    shift
    if "$@" > "$_runtime/last.out" 2>&1; then
        _status=0
    else
        _status=$?
    fi
    if (( _status != _expected )); then
        cat "$_runtime/last.out"
        _fail "Expected exit $_expected, received $_status: $*"
    fi
}

_contains() {
    grep -Fq -- "$1" "${2:-$_runtime/last.out}" || _fail "Missing output: $1"
}

_cleanup() {
    if [[ -n ${_child:-} ]]; then
        kill "$_child" 2>/dev/null || true
        wait "$_child" 2>/dev/null || true
    fi
    if [[ -n ${_foreign:-} ]]; then
        kill "$_foreign" 2>/dev/null || true
        wait "$_foreign" 2>/dev/null || true
    fi
    if [[ -n ${_runtime:-} ]]; then
        printf '[INFO] Test artifacts: %s\n' "$_runtime"
    fi
}

_start_app() {
    : > "$_runtime/boot.out"
    python3 -u "$AGENT_EXECUTABLE" > "$_runtime/boot.out" 2>&1 &
    _child=$!
    local _attempt
    for ((_attempt=0; _attempt<60; _attempt++)); do
        if grep -q '^Agent READY$' "$_runtime/boot.out"; then
            return 0
        fi
        kill -0 "$_child" 2>/dev/null || { cat "$_runtime/boot.out"; _fail 'App failed to start.'; }
        sleep 0.1
    done
    _fail 'App startup timed out.'
}

_stop_app() {
    kill "$_child"
    wait "$_child" 2>/dev/null || true
    _child=
}

_test_thresholds() (
    # Import only to supply deterministic boundary samples to the warning function.
    source "$_root/bin/monitor.sh"
    local _cpu=20 _mem=10 _disk=80
    _warn_thresholds > "$_runtime/threshold.out"
    [[ ! -s $_runtime/threshold.out ]] || _fail 'Threshold equality must not warn.'
    _cpu=20.1 _mem=10.1 _disk=81
    _warn_thresholds > "$_runtime/threshold.out"
    [[ $(grep -c '\[WARNING\]' "$_runtime/threshold.out") == 3 ]] || _fail 'All exceeded metrics must warn.'
)

_test_firewall() (
    source "$_root/bin/monitor.sh"
    local _mock_status='Status: inactive'
    ufw() { printf '%s\n' "$_mock_status"; }
    sudo() { printf '%s\n' "$_mock_status"; }
    _check_firewall > "$_runtime/firewall.out"
    _contains '[WARNING] UFW inactive' "$_runtime/firewall.out"
    _mock_status='Status: active'
    _check_firewall > "$_runtime/firewall.out"
    _contains '[OK] UFW active' "$_runtime/firewall.out"
    sudo() { return 1; }
    _check_firewall > "$_runtime/firewall.out"
    _contains '[WARNING] Cannot verify UFW' "$_runtime/firewall.out"
)

_main() {
    export LC_ALL=C
    [[ $EUID -ne 0 ]] || _fail 'Run tests as an ordinary Linux user.'
    local _root _runtime _child= _foreign= _passed=0 _file _count _before _index
    _root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
    cd -- "$_root"
    mkdir -p .test-runtime
    _runtime=$(mktemp -d "$_root/.test-runtime/run.XXXXXX")
    trap _cleanup EXIT
    for _file in bin/*.sh scripts/*.sh tests/*.sh; do
        bash -n "$_file"
    done
    python3 -c 'import ast,pathlib; ast.parse(pathlib.Path("app/agent_app.py").read_text())'
    _pass 'Bash and Python syntax'
    _expect_exit 1 bash scripts/install.sh --demo
    _expect_exit 1 bash scripts/configure-security.sh --dedicated-lab
    _expect_exit 1 bash scripts/collect-evidence.sh
    _pass 'Deployment utilities reject non-root execution before making changes'
    export AGENT_HOME=$_runtime/app
    export AGENT_PORT=15034
    export AGENT_UPLOAD_DIR=$AGENT_HOME/upload_files
    export AGENT_KEY_PATH=$AGENT_HOME/api_keys/t_secret.key
    export AGENT_LOG_DIR=$_runtime/logs
    export AGENT_ARCHIVE_DIR=$_runtime/archive
    export AGENT_EXECUTABLE=$AGENT_HOME/agent_app.py
    mkdir -p "$AGENT_UPLOAD_DIR" "$AGENT_HOME/api_keys" "$AGENT_LOG_DIR" "$AGENT_ARCHIVE_DIR"
    cp app/agent_app.py "$AGENT_EXECUTABLE"
    printf 'agent_api_key_test\n' > "$AGENT_KEY_PATH"
    [[ -z $(ss -H -ltn 'sport = :15034') ]] || _fail 'TCP 15034 is already occupied; no process was stopped.'

    _expect_exit 1 bash bin/monitor.sh
    _contains 'Application process not found'
    [[ ! -e $AGENT_LOG_DIR/monitor.log ]] || _fail 'Failed health check wrote a success sample.'
    _pass 'Missing application exits 1 without a sample'

    printf 'wrong-key\n' > "$AGENT_KEY_PATH"
    _expect_exit 1 python3 "$AGENT_EXECUTABLE"
    _contains 'Invalid key file'
    printf 'agent_api_key_test\n' > "$AGENT_KEY_PATH"
    _pass 'Invalid key rejects boot'

    python3 -c 'import time; time.sleep(30)' "$AGENT_EXECUTABLE" > /dev/null 2>&1 &
    _foreign=$!
    _start_app
    [[ $(grep -c '\[OK\]' "$_runtime/boot.out") == 5 ]] || _fail 'Five boot checks are required.'
    ss -H -ltn 'sport = :15034' | grep -q '0.0.0.0:15034' || _fail 'Missing IPv4 wildcard listener.'
    _pass 'Non-root boot has five OK checks, READY, and 0.0.0.0:15034'
    cat "$_runtime/boot.out"

    _expect_exit 0 bash bin/monitor.sh
    _contains "PID:$_child"
    [[ $(wc -l < "$AGENT_LOG_DIR/monitor.log") == 1 ]] || _fail 'Expected one sample.'
    grep -Eq '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] PID:[0-9]+ CPU:[0-9]+\.[0-9]% MEM:[0-9]+\.[0-9]% DISK_USED:[0-9]+%$' \
        "$AGENT_LOG_DIR/monitor.log" || _fail 'Unexpected log format.'
    _pass 'Real process, owned port, resources, and timestamped log'
    cat "$_runtime/last.out" "$AGENT_LOG_DIR/monitor.log"
    kill "$_foreign"
    wait "$_foreign" 2>/dev/null || true
    _foreign=
    _pass 'Matching launcher and worker resolve to the actual listening PID'

    _before=$(wc -l < "$AGENT_LOG_DIR/monitor.log")
    flock "$AGENT_LOG_DIR/.monitor.lock" bash bin/monitor.sh > "$_runtime/last.out"
    _contains 'holds the lock'
    [[ $(wc -l < "$AGENT_LOG_DIR/monitor.log") == "$_before" ]] || _fail 'Locked run wrote a sample.'
    _pass 'Concurrent execution is skipped under flock'

    _test_thresholds
    _pass 'Strict threshold boundaries CPU>20, MEM>10, DISK>80'
    _test_firewall
    _pass 'Active, inactive, and inaccessible firewall status; warnings remain non-fatal'

    truncate -s 10485700 "$AGENT_LOG_DIR/monitor.log"
    for ((_index=1; _index<=9; _index++)); do
        printf 'backup-%s\n' "$_index" > "$AGENT_LOG_DIR/monitor.log.$_index"
    done
    _expect_exit 0 bash bin/monitor.sh
    _count=$(find "$AGENT_LOG_DIR" -maxdepth 1 -name 'monitor.log*' -type f | wc -l)
    [[ $_count == 10 ]] || _fail "Expected ten total log files; got $_count."
    [[ $(stat -c %s "$AGENT_LOG_DIR/monitor.log") -lt 10485760 ]] || _fail 'Current log exceeds 10MiB.'
    [[ $(stat -c %s "$AGENT_LOG_DIR/monitor.log.1") == 10485700 ]] || _fail 'Rotation lost the previous file.'
    _contains 'backup-8' "$AGENT_LOG_DIR/monitor.log.9"
    _pass 'Pre-append rotation preserves data and keeps ten files within 10MiB'

    _stop_app
    python3 -c 'import time; time.sleep(30)' "$AGENT_EXECUTABLE.fake" > /dev/null 2>&1 &
    _child=$!
    sleep 0.1
    _expect_exit 1 bash bin/monitor.sh
    _contains 'Application process not found'
    _stop_app
    _pass 'Filename substring does not match an application argv token'
    # Keep the matching process alive but do not bind a socket.
    python3 -c 'import time; time.sleep(30)' "$AGENT_EXECUTABLE" > /dev/null 2>&1 &
    _child=$!
    sleep 0.1
    _expect_exit 1 bash bin/monitor.sh
    _contains 'is not owned by application PID'
    _pass 'Matching process with missing listener exits 1'
    # A different process owns the listener; the application PID must not pass.
    python3 -m http.server 15034 --bind 127.0.0.1 > "$_runtime/foreign.out" 2>&1 &
    _foreign=$!
    for ((_index=0; _index<50; _index++)); do
        [[ -z $(ss -H -ltn 'sport = :15034') ]] || break
        sleep 0.1
    done
    _expect_exit 1 bash bin/monitor.sh
    kill "$_foreign"
    wait "$_foreign" 2>/dev/null || true
    _foreign=
    _contains 'is not owned by application PID'
    _stop_app
    _pass 'Unrelated listener does not satisfy application health'

    cat > "$AGENT_LOG_DIR/monitor.log" <<'LOG'
[2026-11-25 10:00:00] PID:100 CPU:10.0% MEM:5.0% DISK_USED:20%
[2026-11-25 10:01:00] PID:100 CPU:20.0% MEM:10.0% DISK_USED:40%
[2026-11-25 10:02:00] PID:100 CPU:30.0% MEM:15.0% DISK_USED:60%
malformed line
LOG
    _expect_exit 0 bash bin/report.sh
    _contains 'Average: 20.0%'
    _contains 'Average: 10.0%'
    _contains 'Average: 40.0%'
    _contains 'Maximum: 30.0% at 2026-11-25 10:02:00'
    _contains 'Minimum: 10.0% at 2026-11-25 10:00:00'
    _contains 'Data Points: 3 samples'
    _pass 'Report averages, extrema timestamps, sample count, and malformed line handling'

    _expect_exit 0 bash bin/report.sh '2026-11-25 10:01:00' '2026-11-25 10:01:00'
    _contains 'Data Points: 1 samples'
    _expect_exit 0 bash bin/report.sh '2026-11-26 00:00:00'
    _contains 'No matching samples'
    _expect_exit 1 bash bin/report.sh '2026-11-26 00:00:00' '2026-11-25 00:00:00'
    _expect_exit 1 bash bin/report.sh '2026-02-30 00:00:00'
    _pass 'Inclusive report range, no samples, reversed range, and invalid calendar date'

    printf 'old-log\n' > "$AGENT_LOG_DIR/old.log"
    printf 'new-log\n' > "$AGENT_LOG_DIR/new.log"
    printf 'expired-archive\n' | gzip > "$AGENT_ARCHIVE_DIR/expired.gz"
    touch -d '8 days ago' "$AGENT_LOG_DIR/old.log" "$AGENT_LOG_DIR/monitor.log" "$AGENT_LOG_DIR/boot.log"
    touch -d '31 days ago' "$AGENT_ARCHIVE_DIR/expired.gz"
    _expect_exit 0 bash bin/archive.sh
    [[ ! -e $AGENT_LOG_DIR/old.log && ! -e $AGENT_ARCHIVE_DIR/expired.gz ]] || _fail 'Retention left expired files.'
    [[ -f $AGENT_LOG_DIR/new.log && -f $AGENT_LOG_DIR/monitor.log && -f $AGENT_LOG_DIR/boot.log ]] || _fail 'Retention removed an active/recent log.'
    _file=$(find "$AGENT_ARCHIVE_DIR" -name 'old.log.*.gz' -print -quit)
    [[ $(gzip -cd -- "$_file") == old-log ]] || _fail 'Compressed archive differs from source.'
    _expect_exit 0 bash bin/archive.sh
    _pass 'Seven-day compression, thirty-day deletion, active log exclusions, and empty targets'

    AGENT_ARCHIVE_DIR=$_runtime/missing _expect_exit 1 bash bin/archive.sh
    _contains '[WARNING]'
    _pass 'Missing archive directory returns a safe warning'

    _start_app
    # A failed status probe is a warning, never a failed health check.
    _expect_exit 0 bash bin/monitor.sh
    if ! grep -Eq '\[(OK|WARNING)\].*(UFW|firewall)' "$_runtime/last.out"; then
        _fail 'Missing firewall state output.'
    fi
    _pass 'Firewall probe produces an explicit state without aborting healthy collection'
    _stop_app
    printf '\nRESULT: %s checks passed\n' "$_passed"
    _cleanup
    trap - EXIT
}

_main "$@"
