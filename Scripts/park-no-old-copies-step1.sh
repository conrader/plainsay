#!/bin/bash
set -euo pipefail

base=${1:?Expected base commit}
new=${2:?Expected new commit}
main=refs/heads/main
d=/var/lib/plainsay-deploy/bin
source=kit/ovh-deploy-command.sh
prev="$d/deploy-command.prev-${base:0:7}"

stop() { printf 'STOP %s\n' "$1" >&2; exit 1; }

# A read-only lock shared with undo serializes the ref check and installation.
exec 9<"$d"
flock -x 9
remote=$(git ls-remote --exit-code origin "$main" 2>/dev/null) || stop "Could not read origin/main"
if [[ $remote == "$new"$'\t'"$main" ]]; then
    printf 'Already applied at %s\n' "$new"
    exit 0
fi
[[ $remote == "$base"$'\t'"$main" ]] || stop "origin/main is outside the expected rollout"
[[ $(git rev-parse HEAD) == "$new" ]] || stop "Wrong rollout checkout"
git merge-base --is-ancestor "$base" "$new" || stop "Rollout is not a fast-forward"
[[ $(git hash-object --no-filters "$source") == "$(git rev-parse "$new:$source")" ]] ||
    stop "Deploy command differs from the rollout commit"

if ! sudo -n test -e "$prev"; then
    sudo -n test -f "$d/deploy-command"
    sudo -n test ! -L "$d/deploy-command"
    sudo -n test ! -L "$prev"
    sudo -n test ! -L "$d/.deploy-command.prev.next"
    # Publish the complete copy without clobbering an existing backup.
    sudo -n cp -aT -- "$d/deploy-command" "$d/.deploy-command.prev.next"
    sudo -n mv -nT -- "$d/.deploy-command.prev.next" "$prev"
fi
sudo -n test -f "$prev"
sudo -n test ! -L "$prev"
sudo -n test ! -L "$d/.deploy-command.next"
sudo -n install -o root -g root -m 0755 -- "$source" "$d/.deploy-command.next"
sudo -n mv -T -- "$d/.deploy-command.next" "$d/deploy-command"

# The ancestry check above guarantees a fast-forward. The lease pins its base.
git push --quiet --no-follow-tags --force-with-lease="$main:$base" origin "$new:$main" 2>/dev/null ||
    stop "Could not fast-forward origin/main"
