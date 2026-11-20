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
    # Lock the producer's directory. The '/.' suffix prevents creating a missing path.
    if ! newest=$("$@" /usr/bin/flock -s -w 20 "$root/backups/." /usr/bin/find "$root/backups" \
                  -maxdepth 1 -type f -name "$DAILY_PATTERN" -printf '%f\n' |
                  LC_ALL=C sort | tail -n 1) || [[ -z $newest ]]; then
        printf '%s\n' 'ALERT newest on-box daily backup is unavailable'
        return 1
    fi
    stamp=${newest#plainsay-daily-}
    if ! created=$(date -u -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}" +%s) ||
       ! now=$(date -u +%s); then
        printf '%s\n' 'ALERT newest on-box daily backup has an invalid timestamp'
        return 1
    fi
    if (( now - created > 172800 )); then
        printf 'ALERT newest on-box daily backup is older than 2 days (%s)\n' "$newest"
        return 1
    fi
}

reserve_freshness_notice() {
    # init_check holds the on-box freshness lock for this invocation.
    local notice=$STATE/backup-freshness-notice now last pending
    now=$(date -u +%s) || return 1
    if [[ -e $notice || -L $notice ]]; then
        if [[ ! -f $notice || -L $notice ]] || ! read -r last <"$notice" ||
           [[ ! $last =~ ^[1-9][0-9]{0,11}$ ]]; then
            log 'freshness_wake=suppressed state unavailable'
            return 1
        fi
        if (( now - last < 86400 )); then
            log 'freshness_wake=suppressed within 24h of last attempt'
            return 1
        fi
    fi
    # Reserve before calling the notifier so a failed attempt also counts.
    if ! pending=$(mktemp -- "$notice.XXXXXX"); then
        log 'freshness_wake=suppressed state unavailable'
        return 1
    fi
    if ! printf '%s\n' "$now" >"$pending" || ! mv -fT -- "$pending" "$notice"; then
        rm -f -- "$pending"
        log 'freshness_wake=suppressed state unavailable'
        return 1
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    check=backup-rotate
    if [[ $# == 1 && $1 == --check-freshness ]]; then
        check=backup-freshness
    elif [[ $# != 0 ]]; then
        printf 'Usage: %s [--check-freshness]\n' "$0" >&2
        exit 2
    fi
    # shellcheck source=/dev/null
    source /home/ubuntu/work/Plainsay/cron/lib.sh
    init_check "$check"
    root=${PLAINSAY_BACKUP_ROOT:-/var/lib/plainsay}
    run_as=(sudo -n)
    if [[ -n ${PLAINSAY_BACKUP_ROOT:-} ]]; then run_as=(); fi

    if [[ $check == backup-freshness ]]; then
        if alert=$(check_daily_backup "$root" "${run_as[@]}" 2>/dev/null); then exit 0; fi
        log "$alert"
        if reserve_freshness_notice; then
            notice_rc=0
            timeout --foreground 30 /home/ubuntu/sb/bin/sb-codejob notify --agent infra-caretaker \
                --host ovh --exit-code 1 --started "$STARTED" --ended "$(ts)" \
                --label plainsay-onbox-freshness --source cron <<<"$alert" >/dev/null 2>&1 || notice_rc=$?
            log "failure_wake_exit=$notice_rc"
        fi
        exit 1
    fi

    status=0
    deleted=$(rotate_manual_backups "$root" "${run_as[@]}" 2>/dev/null) || status=$?
    count=$(printf '%s' "$deleted" | grep -c . || true)
    log "rc=$status deleted=$count ${deleted//$'\n'/ }"
    exit "$status"
fi
