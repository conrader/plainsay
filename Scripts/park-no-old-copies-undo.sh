#!/bin/bash
set -euo pipefail

base=${1:?Expected base commit}
new=${2:?Expected new commit}
main=refs/heads/main
d=/var/lib/plainsay-deploy/bin
prev="$d/deploy-command.prev-${base:0:7}"

stop() { printf 'STOP %s\n' "$1" >&2; exit 1; }

exec 9<"$d"
flock -x 9
remote=$(git ls-remote --exit-code origin "$main" 2>/dev/null) || stop "Could not read origin/main"
[[ $remote == "$new"$'\t'"$main" || $remote == "$base"$'\t'"$main" ]] ||
    stop "origin/main is outside the expected rollout"

if sudo -n test -e "$prev" || sudo -n test -L "$prev"; then
    sudo -n test -f "$prev"
    sudo -n test ! -L "$prev"
    current="$d/deploy-command"
    saved_metadata=$(stat -c '%u:%g:%a:%y' -- "$prev")
    if [[ ! -f $current || -L $current ]] ||
        [[ $(stat -c '%u:%g:%a:%y' -- "$current") != "$saved_metadata" ]] ||
        ! cmp -s -- "$prev" "$current"; then
        sudo -n test ! -L "$d/.deploy-command.next"
        sudo -n cp -aT -- "$prev" "$d/.deploy-command.next"
        sudo -n mv -T -- "$d/.deploy-command.next" "$current"
    fi
elif [[ $remote == "$new"$'\t'"$main" ]]; then
    stop "Saved deploy command is missing"
fi

if [[ $remote == "$new"$'\t'"$main" ]]; then
    git push --quiet --no-follow-tags --force-with-lease="$main:$new" origin "$base:$main" 2>/dev/null ||
        stop "Could not restore origin/main"
fi
