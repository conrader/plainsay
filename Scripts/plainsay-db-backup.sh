#!/bin/bash
# OVH user cron wrapper. Its worker runs as the database service account.
set -euo pipefail

backup_database() (
    set -euo pipefail
    export LC_ALL=C
    umask 077
    local source=$1 target=$2 stage name digest published
    local pattern='plainsay-daily-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.db'
    [[ -f $source && ! -L $source && $(realpath -e -- "$source") == "$source" ]]
    cd -P -- "$target"
    [[ $PWD == "$target" ]]
    exec 8<.
    flock -x -w 20 8

    name=plainsay-daily-$(date -u +%Y%m%dT%H%M%SZ).db
    [[ ! -e $name && ! -L $name ]]
    for old in $pattern; do
        if [[ -f $old && $old > $name ]]; then exit 1; fi
    done

    stage=$(mktemp -d -- "$target/.plainsay-backup.XXXXXX")
    trap 'rm -rf -- "$stage"' EXIT
    (
        cd -- "$stage"
        sqlite3 -readonly "$source" '.timeout 30000' '.backup snapshot.db'
        [[ $(sqlite3 snapshot.db 'PRAGMA journal_mode=DELETE;') == delete ]]
        [[ $(sqlite3 -readonly snapshot.db 'PRAGMA integrity_check;') == ok ]]
    ) 2>/dev/null
    digest=$(sha256sum -- "$stage/snapshot.db")
    digest=${digest%% *}
    [[ $digest =~ ^[a-f0-9]{64}$ && -s $stage/snapshot.db ]]

    mv -nT -- "$stage/snapshot.db" "$name"
    [[ ! -e $stage/snapshot.db && -f $name && ! -L $name ]]
    if ! published=$(sha256sum -- "$name") || [[ ${published%% *} != "$digest" ]]; then
        rm -- "$name"
        exit 1
    fi

    for old in $pattern; do
        if [[ -f $old && ! -L $old && $old < $name ]]; then rm -- "$old"; fi
    done
    printf 'file=%s size=%s integrity=ok retention=1\n' "$name" "$(stat -c %s -- "$name")"
)

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    # Provided by the existing OVH cron installation.
    # shellcheck source=/dev/null
    source /home/ubuntu/work/Plainsay/cron/lib.sh
    init_check db-backup
    if report=$(sudo -n -u plainsay /bin/bash -c "$(declare -f backup_database); backup_database \"\$@\"" _ \
            /var/lib/plainsay/plainsay.db /var/lib/plainsay/backups 2>/dev/null); then
        log "$report"
    else
        log "FAIL verified SQLite backup or retention step failed"
        exit 1
    fi
fi
