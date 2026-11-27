#!/usr/bin/env bash
set -Eeuo pipefail

_fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

_check_directory() (
    source "$_root/scripts/collect-evidence.sh"
    _assert_access "$_user" "$1" "$2"
)

_main() {
    export LC_ALL=C
    [[ $EUID -eq 0 && $# -eq 1 ]] || _fail 'Usage: sudo bash tests/access.sh existing-non-root-user'
    local _user=$1 _root _runtime _primary _alternate _mode _status _result
    [[ $(id -u "$_user") -ne 0 ]] || _fail 'A non-root test account is required.'
    _primary=$(id -gn "$_user")
    _alternate=$(id -nG "$_user" | tr ' ' '\n' | awk -v p="$_primary" '$0!=p {print; exit}')
    [[ -n $_alternate ]] || _fail 'An existing supplementary group is required.'
    _root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
    _runtime=$(mktemp -d /run/agent-access-regression.XXXXXX)
    chmod 0755 "$_runtime"
    install -d -o root -g "$_alternate" -m 2770 "$_runtime/shared"
    install -d -o root -g root -m 0700 "$_runtime/restricted"
    printf 'Access regression time: %s\n' "$(date --iso-8601=seconds)"
    runuser -u "$_user" -- id
    stat -c '%U:%G:%a %n' "$_runtime/shared" "$_runtime/restricted"
    for _mode in -r -w -x; do
        if runuser -u "$_user" -- /usr/bin/test "$_mode" "$_runtime/shared"; then
            _status=0
        else
            _status=$?
        fi
        printf 'External test %s exit: %s\n' "$_mode" "$_status"
    done
    # Verify a real write/read before evaluating the permission-check helper.
    runuser -u "$_user" -- /bin/bash -c '
        _file=$(mktemp "$1/.probe.XXXXXX") || exit
        trap '\''rm -f -- "$_file"'\'' EXIT
        printf "probe\n" > "$_file" && [[ $(cat "$_file") == probe ]]
    ' _ "$_runtime/shared"
    printf '[PASS] Actual file creation, write, and read through a supplementary group.\n'
    _check_directory "$_runtime/shared" yes
    _check_directory "$_runtime/restricted" no
    if _result=$(_check_directory "$_runtime/restricted" yes 2>&1); then
        _fail 'A denied directory was incorrectly accepted.'
    fi
    printf '[PASS] Expected rejection when a restricted directory requires shared access.\n'
    printf '[PASS] Directory checker accepts shared access and rejects denied access.\n'
    rmdir -- "$_runtime/shared" "$_runtime/restricted" "$_runtime"
}

_main "$@"
