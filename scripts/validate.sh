#!/usr/bin/env bash
set -Eeuo pipefail

_main() {
    local _root
    _root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
    cd -- "$_root"
    mkdir -p evidence
    {
        printf 'Validation time: %s\n' "$(date --iso-8601=seconds)"
        uname -a
        cat /etc/os-release
        id
        printf '\n'
        bash tests/run.sh
    } 2>&1 | tee evidence/local-validation.log
}

_main "$@"
