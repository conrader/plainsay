#!/bin/bash
# Staged OVH rollout. DRY_RUN=0 explicitly applies the plan as ubuntu with sudo -n.
set -euo pipefail
export PATH=/usr/bin:/bin LC_ALL=C
umask 077

repo=/home/ubuntu/work/Plainsay/privacy-s8
cron=/home/ubuntu/work/Plainsay/cron
bin=/usr/local/bin
cron_d=/etc/cron.d
base=8dff62127401436fe286444dc7a64ba4b5fd97bc
mode=install
if [[ $# == 1 && $1 == --undo ]]; then
    mode=undo
elif [[ $# != 0 ]]; then
    printf 'Usage: %s [--undo]\n' "$0" >&2
    exit 2
fi
dry_run=${DRY_RUN:-1}
stop() { printf 'STOP %s\n' "$1" >&2; exit 1; }
[[ $dry_run == 0 || $dry_run == 1 ]] || stop 'DRY_RUN must be 0 or 1'
[[ $(hostname -s) == vps-98fe3bb4 && $(id -un) == ubuntu ]] || stop 'Run as ubuntu on OVH vps-98fe3bb4'
[[ $(sudo -n /usr/bin/id -u) == 0 ]] || stop 'Root access via sudo -n is required'
for directory in "$cron" "$bin" "$cron_d"; do
    [[ -d $directory && $(realpath -e -- "$directory") == "$directory" ]] || stop "Unexpected directory: $directory"
done
[[ $(stat -c '%U:%G:%a' -- "$bin" "$cron_d") == $'root:root:755\nroot:root:755' ]] ||
    stop 'Unexpected ownership or mode on privileged directories'

# Both directions hold this lock from preflight through the last update.
exec 9<"$cron_d"
flock -n 9 || stop 'Another backup-script park is running'
tmp=$(mktemp -d -- /tmp/plainsay-privacy-s8.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT

digest() { sha256sum <"$1" | cut -d ' ' -f 1; }
regular() { [[ -f $1 && ! -L $1 && $(stat -c %h -- "$1") == 1 ]]; }
targets=("$cron/plainsay-db-backup.sh" "$cron/plainsay-backup-rotate.sh" "$bin/plainsay-offbox-backup" "$cron_d/plainsay-offbox")
sources=("$repo/Scripts/plainsay-db-backup.sh" "$repo/Scripts/plainsay-backup-rotate.sh" \
         "$repo/Scripts/plainsay-offbox-backup.py" "$tmp/offbox.new")
metadata=(ubuntu:ubuntu:755 ubuntu:ubuntu:755 root:root:755 root:root:644)
legacy=(
    bfe3091e55c1533bf6f645a76ed914fd8debfcba42e0f812cc7c1f3f37989882
    f3526fcc787057b36b701796eb2fa1a5e03218f9f39e5f64ca7d592d9805c78c
    d74edd53f36cd3afeed11500daa07ea8405f1662d1d276936d8d9bd191eb4f82
    98868456350c171935bf6c4f82662c81632b25d50baa0f92430650c690f13fb2
)
cat >"${sources[3]}" <<EOF
# Host timezone: Etc/UTC. Plainsay's local backup runs at 02:17 UTC.
SHELL=/bin/sh
PATH=$bin:/usr/bin:/bin
37 4 * * * ubuntu $bin/plainsay-offbox-backup
# Alert when the newest encrypted daily backup is older than 2 days or unavailable.
53 * * * * ubuntu $bin/plainsay-offbox-backup --check-freshness >/dev/null 2>&1
EOF
replacement=(
    e17df840bd23ff3624b9bf1308ee69c8db0c535af37fc5a143d8a9a32d8ccb5c
    67a2ea80a869250be80fd7ddce6d443eb50d2ab90d7730d2b08dff55c06510f1
    3e7e47cd320f161884d13d34692883ffc6944772e6ade5ac24e3a35f0e5c7604
    "$(digest "${sources[3]}")"
)
if [[ $mode == install ]]; then
    [[ $(git -C "$repo" symbolic-ref --short HEAD) == docs/privacy-backup-retention ]] || stop 'Wrong checkout branch'
    git -C "$repo" merge-base --is-ancestor "$base" HEAD || stop 'Checkout does not contain the reviewed base'
    [[ -r $cron/lib.sh && -x /home/ubuntu/sb/bin/sb-codejob ]] || stop 'Cron helpers or notifier are missing'
    for i in 0 1 2; do
        # Stage the checked bytes under a private directory before any live writes.
        source=${sources[i]}
        [[ -f $source && ! -L $source ]] || stop "Unexpected source: $source"
        sources[i]="$tmp/script.$i"
        cp -T -- "$source" "${sources[i]}"
        [[ $(digest "${sources[i]}") == "${replacement[i]}" ]] || stop "Source checksum mismatch: $source"
    done
fi

for i in "${!targets[@]}"; do
    target=${targets[i]}
    prev=$target.prev
    if ! regular "$target" || [[ $(stat -c '%U:%G:%a' -- "$target") != "${metadata[i]}" ]]; then
        stop "Unexpected installed file or metadata: $target"
    fi
    current[i]=$(digest "$target")
    [[ ${current[i]} == "${legacy[i]}" || ${current[i]} == "${replacement[i]}" ]] ||
        stop "Unrecognized installed checksum: $target"
    if [[ -e $prev || -L $prev ]]; then
        if ! regular "$prev" || [[ $(digest "$prev") != "${legacy[i]}" ||
            $(stat -c '%U:%G:%a' -- "$prev") != "${metadata[i]}" ]]; then
            stop "Unexpected rollback file: $prev"
        fi
    elif [[ ${current[i]} == "${replacement[i]}" ]]; then
        stop "Rollback file is missing: $prev"
    fi
done

# Match the reviewed comments by content so unrelated crontab line shifts are safe.
crontab -l >"$tmp/crontab.current" || stop 'Cannot read the ubuntu crontab'
awk -v cron="$cron" -v mode="$mode" '
    BEGIN {
        rotate_old = "# Plainsay DB backup rotation: delete backup copies older than 30 days (privacy policy §8), hourly."
        rotate_new = "# Plainsay DB backup rotation: remove manual pre-change copies after 30 days, hourly."
        daily_old = "# Plainsay daily online DB backup (sqlite3 .backup as plainsay) into /var/lib/plainsay/backups; rotated after 30 days."
        daily_new = "# Plainsay daily online DB backup: keep the newest verified daily copy (privacy policy §8)."
        rotate_path = cron "/plainsay-backup-rotate.sh"
        daily_path = cron "/plainsay-db-backup.sh"
        rotate_job = "41 * * * * " rotate_path " >/dev/null 2>&1"
        daily_job = "17 2 * * * " daily_path " >/dev/null 2>&1"
        freshness_job = "47 * * * * " rotate_path " --check-freshness >/dev/null 2>&1"
    }
    need != "" && $0 != need { bad = 1 }
    { need = "" }
    $0 == rotate_old || $0 == rotate_new {
        old_rotate += ($0 == rotate_old)
        new_rotate += ($0 == rotate_new)
        need = rotate_job
        print (mode == "install" ? rotate_new : rotate_old)
        next
    }
    $0 == daily_old || $0 == daily_new {
        old_daily += ($0 == daily_old)
        new_daily += ($0 == daily_new)
        need = daily_job
        print (mode == "install" ? daily_new : daily_old)
        next
    }
    $0 == rotate_job { rotate++ }
    $0 == daily_job {
        daily++
        print
        if (mode == "install") print freshness_job
        next
    }
    $0 == freshness_job { freshness++; next }
    $0 !~ /^[[:space:]]*#/ && (index($0, rotate_path) || index($0, daily_path)) && $0 != rotate_job { bad = 1 }
    { print }
    END {
        old = old_rotate == 1 && old_daily == 1 && !new_rotate && !new_daily && !freshness
        new = new_rotate == 1 && new_daily == 1 && !old_rotate && !old_daily && freshness == 1
        if (bad || need != "" || rotate != 1 || daily != 1 || !(old || new)) exit 1
    }
' "$tmp/crontab.current" >"$tmp/crontab.next" || stop 'Plainsay backup entries in the ubuntu crontab differ from the reviewed layout'
crontab -n "$tmp/crontab.next" || stop 'Candidate crontab failed syntax validation'

printf '%s DRY_RUN=%s\n' "$mode" "$dry_run"
for i in "${!targets[@]}"; do
    if [[ $mode == install ]]; then goal[i]=${replacement[i]}; else goal[i]=${legacy[i]}; fi
    printf '%s  %s (current %s)\n' "${goal[i]}" "${targets[i]}" "${current[i]}"
done
printf '%s  ubuntu crontab (current %s)\n' "$(digest "$tmp/crontab.next")" "$(digest "$tmp/crontab.current")"
if [[ $dry_run == 1 ]]; then exit 0; fi

update_file() (
    local i=$1 action=$2 target=${targets[$1]} stage
    local run=()
    if (( i >= 2 )); then run=(sudo -n); fi
    if ! regular "$target" || [[ $(digest "$target") != "${current[i]}" ]]; then
        stop "Installed file changed during preflight: $target"
    fi
    stage=$("${run[@]}" mktemp -d -- "${target%/*}/.privacy-s8.XXXXXX")
    trap '"${run[@]}" rm -rf -- "$stage"' EXIT
    case $action in
        save)
            # Create a complete no-clobber copy before publishing the single .prev name.
            "${run[@]}" cp -pnT -- "$target" "$stage/prev"
            "${run[@]}" mv -nT -- "$stage/prev" "$target.prev"
            if "${run[@]}" test -e "$stage/prev"; then stop "Rollback file appeared during preflight: $target.prev"; fi
            ;;
        install)
            local owner group permissions
            IFS=: read -r owner group permissions <<<"${metadata[i]}"
            "${run[@]}" install -o "$owner" -g "$group" -m "$permissions" -- "${sources[i]}" "$stage/next"
            "${run[@]}" mv -fT -- "$stage/next" "$target"
            ;;
        undo)
            if ! regular "$target.prev" || [[ $(digest "$target.prev") != "${legacy[i]}" ]]; then
                stop "Rollback file changed during preflight: $target.prev"
            fi
            "${run[@]}" cp -pT -- "$target.prev" "$stage/next"
            "${run[@]}" mv -fT -- "$stage/next" "$target"
            ;;
    esac
)

update_crontab() {
    crontab -l >"$tmp/crontab.recheck"
    cmp -s -- "$tmp/crontab.current" "$tmp/crontab.recheck" || stop 'The ubuntu crontab changed during preflight'
    if ! cmp -s -- "$tmp/crontab.current" "$tmp/crontab.next"; then
        crontab "$tmp/crontab.next"
    fi
}

if [[ $mode == install ]]; then
    for i in "${!targets[@]}"; do
        if [[ ! -e ${targets[i]}.prev ]]; then update_file "$i" save; fi
    done
    for i in "${!targets[@]}"; do
        if [[ ${current[i]} != "${goal[i]}" ]]; then update_file "$i" install; fi
    done
    update_crontab
else
    update_crontab
    for i in 3 2 1 0; do
        if [[ ${current[i]} != "${goal[i]}" ]]; then update_file "$i" undo; fi
    done
fi

for i in "${!targets[@]}"; do
    [[ $(digest "${targets[i]}") == "${goal[i]}" ]] || stop "Final checksum mismatch: ${targets[i]}"
done
crontab -l >"$tmp/crontab.recheck"
cmp -s -- "$tmp/crontab.next" "$tmp/crontab.recheck" || stop 'Final crontab check failed'
