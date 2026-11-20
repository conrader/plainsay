#!/bin/bash
# OVH hourly age-based cleanup of manual pre-change copies. The database
# producer verifies replacements and manages the stamped daily snapshots.
set -euo pipefail

rotate_manual_backups() {
    local root=$1
    shift
    local daily='plainsay-daily-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.db'
    "$@" find "$root" -maxdepth 2 -type f -mmin +43200 \
        \( -path "$root/backups/*" ! -name "$daily" -o -path "$root/plainsay-pre-*.db*" \) \
        ! -name 'plainsay.db' ! -name 'plainsay.db-wal' ! -name 'plainsay.db-shm' \
        -print -delete
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
    exit "$status"
fi
