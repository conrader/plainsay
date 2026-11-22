#!/bin/bash
# OVH hourly age-based cleanup of manual pre-change copies. The database
# producer verifies replacements and manages the stamped daily snapshots.
set -euo pipefail

DAILY_PATTERN='plainsay-daily-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.db'

rotate_manual_backups() {
    local root=$1
    shift
    "$@" find "$root" -maxdepth 2 -type f -mmin +43200 \
        \( -path "$root/backups/*" ! -name "$DAILY_PATTERN" -o -path "$root/plainsay-pre-*.db*" \) \
        ! -name 'plainsay.db' ! -name 'plainsay.db-wal' ! -name 'plainsay.db-shm' \
        -print -delete
}

check_daily_backup() {
    local root=$1 newest stamp created now
    shift
    if ! newest=$("$@" find "$root/backups" -maxdepth 1 -type f -name "$DAILY_PATTERN" -printf '%f\n' |
                  LC_ALL=C sort | tail -n 1) || [[ -z $newest ]]; then
        log "ALERT newest on-box daily backup is unavailable"
        return 1
    fi
    stamp=${newest#plainsay-daily-}
    if ! created=$(date -u -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}" +%s) ||
       ! now=$(date -u +%s); then
        log "ALERT newest on-box daily backup has an invalid timestamp"
        return 1
    fi
    if (( now - created > 172800 )); then
        log "ALERT newest on-box daily backup is older than 2 days ($newest)"
        return 1
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    # shellcheck source=/dev/null
    source /home/ubuntu/work/Plainsay/cron/lib.sh
    init_check backup-rotate
    root=${PLAINSAY_BACKUP_ROOT:-/var/lib/plainsay}
    run_as=(sudo -n)
    if [[ -n ${PLAINSAY_BACKUP_ROOT:-} ]]; then run_as=(); fi
    status=0
    deleted=$(rotate_manual_backups "$root" "${run_as[@]}" 2>/dev/null) || status=$?
    count=$(printf '%s' "$deleted" | grep -c . || true)
    log "rc=$status deleted=$count ${deleted//$'\n'/ }"
    check_daily_backup "$root" "${run_as[@]}" 2>/dev/null || status=1
    /usr/local/bin/plainsay-offbox-backup --check-freshness || status=1
    exit "$status"
fi
