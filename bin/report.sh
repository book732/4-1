#!/usr/bin/env bash
set -Eeuo pipefail

_main() {
    export LC_ALL=C
    local _log=${AGENT_LOG_DIR:-/var/log/agent-app}/monitor.log
    local _start=${1:-} _end=${2:-}
    if (( $# > 2 )) || [[ ! -r $_log ]]; then
        printf '[ERROR] Usage: report.sh ["YYYY-MM-DD HH:MM:SS" ["YYYY-MM-DD HH:MM:SS"]]; readable monitor.log required.\n' >&2
        return 1
    fi
    local _value
    for _value in "$_start" "$_end"; do
        if [[ -n $_value ]] && { [[ ! $_value =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] ||
            [[ $(date -d "$_value" '+%F %T' 2>/dev/null) != "$_value" ]]; }; then
            printf '[ERROR] Invalid timestamp: %s\n' "$_value" >&2
            return 1
        fi
    done
    if [[ -n $_start && -n $_end && $_start > $_end ]]; then
        printf '[ERROR] Start time must not follow end time.\n' >&2
        return 1
    fi
    awk -v start="$_start" -v end="$_end" '
        /^\[[0-9-]+ [0-9:]+\] PID:[0-9]+ CPU:[0-9.]+% MEM:[0-9.]+% DISK_USED:[0-9.]+%$/ {
            stamp=substr($0,2,19)
            if ((start!="" && stamp<start) || (end!="" && stamp>end)) next
            split($4,c,":"); split($5,m,":"); split($6,d,":")
            values[1]=c[2]+0; values[2]=m[2]+0; values[3]=d[2]+0
            for(i=1;i<=3;i++) {
                sum[i]+=values[i]
                if(n==0 || values[i]<min[i]) {min[i]=values[i]; mint[i]=stamp}
                if(n==0 || values[i]>max[i]) {max[i]=values[i]; maxt[i]=stamp}
            }
            n++
        }
        END {
            print "====== STATISTICS REPORT ======"
            if(n==0) {print "[INFO] No matching samples."; exit}
            names[1]="CPU"; names[2]="Memory"; names[3]="Disk"
            for(i=1;i<=3;i++) {
                printf "[%s]\nAverage: %.1f%%\nMaximum: %.1f%% at %s\nMinimum: %.1f%% at %s\n", \
                    names[i],sum[i]/n,max[i],maxt[i],min[i],mint[i]
            }
            printf "[Samples]\nData Points: %d samples\n", n
        }' "$_log"
}

_main "$@"
