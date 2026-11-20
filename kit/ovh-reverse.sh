#!/bin/bash
set -euo pipefail
umask 077
# shellcheck source=kit/ovh-common.sh
source "$(dirname "$0")/ovh-common.sh"

case "${1:-}" in
    -h|--help) printf 'Usage: sudo %s\n' "$0"; exit 0 ;;
esac
[[ $# == 0 ]] || die 'This script takes no arguments. See --help.'
require_tools flock setfacl pgrep userdel groupdel
lock_ovh
if [[ ! -e $BACKUP && ! -L $BACKUP ]]; then
    if getent passwd "$DEPLOY_USER" >/dev/null || getent group "$DEPLOY_GROUP" >/dev/null ||
        [[ -e $DEPLOY_HOME || -L $DEPLOY_HOME ]]; then
        die 'No kit backup for the existing account, group or home.'
    fi
    printf 'No active OVH provisioning to reverse.\n'
    exit 0
fi
assert_backup

deploy_uid=''
deploy_gid=''
if account=$(getent passwd "$DEPLOY_USER"); then
    IFS=: read -r _ _ deploy_uid _ _ home _ <<< "$account"
    [[ $home == "$DEPLOY_HOME" ]] || die 'Deploy account home changed.'
    [[ ! -f $BACKUP/uid || $(cat "$BACKUP/uid") == "$deploy_uid" ]] || die 'Deploy account ID changed.'
fi
if group=$(getent group "$DEPLOY_GROUP"); then
    IFS=: read -r _ _ deploy_gid members <<< "$group"
    [[ -z $members || $members == "$LEGACY_USER" ]] || die 'Unexpected shared group membership.'
    [[ ! -f $BACKUP/gid || $(cat "$BACKUP/gid") == "$deploy_gid" ]] || die 'Deploy group ID changed.'
fi
if [[ -e $DEPLOY_HOME || -L $DEPLOY_HOME ]]; then
    check_tree "$DEPLOY_HOME"
    if [[ -e $DEPLOY_HOME/.ssh || -L $DEPLOY_HOME/.ssh ]]; then
        check_tree "$DEPLOY_HOME/.ssh"
        rm -f -- "$DEPLOY_HOME/.ssh/authorized_keys"
    fi
fi
if [[ -n $deploy_uid ]]; then
    if pgrep -u "$deploy_uid" >/dev/null; then
        die 'The key was removed. Let existing deploy sessions finish, then rerun.'
    else
        [[ $? == 1 ]] || die 'Could not check for deploy sessions.'
    fi
fi

check_tree "$UPDATES"
check_tree "$UPDATES/releases"
check_tree "$SITE"
mapfile -t owners < "$BACKUP/owners"
[[ ${#owners[@]} == 3 ]] || die 'Missing original document root ownership.'
trees=("$UPDATES" "$UPDATES/releases" "$SITE")
for index in 0 1 2; do
    [[ ${owners[index]} =~ ^[0-9]+:[0-9]+$ ]] || die 'Invalid original document root ownership.'
    tree=${trees[index]}
    if [[ -n $deploy_gid ]]; then
        find -P "$tree" -type d -exec setfacl -n -x "g:$deploy_gid,d:g:$deploy_gid" -- {} +
        find -P "$tree" -type f -exec setfacl -n -x "g:$deploy_gid" -- {} +
    fi
    # Files created since provisioning have no original owner in the backup.
    # Transfer them before deleting their system UID.
    if [[ -n $deploy_uid && $index != 0 ]]; then
        find -P "$tree" -uid "$deploy_uid" \
            -exec chown -h --from="$deploy_uid" "${owners[index]}" -- {} +
    fi
done
if [[ -n $deploy_uid ]]; then
    find -P "$UPDATES" -path "$UPDATES/releases" -prune -o -uid "$deploy_uid" \
        -exec chown -h --from="$deploy_uid" "${owners[0]}" -- {} +
fi

index=0
while IFS= read -r -d '' path; do
    if [[ -e $path && ! -L $path ]] && real_path "$path"; then
        setfacl --restore="$BACKUP/acl.$index"
    else
        printf 'Skipped missing or replaced baseline path %q\n' "$path" >&2
    fi
    index=$((index + 1))
done < "$BACKUP/paths"

if [[ -f $BACKUP/created-update-backups && -d $UPDATES/.release-backups ]] &&
    real_path "$UPDATES/.release-backups"; then
    rmdir --ignore-fail-on-non-empty -- "$UPDATES/.release-backups"
fi
if [[ -n $deploy_uid ]]; then userdel "$DEPLOY_USER"; fi
if [[ -n $deploy_gid ]]; then groupdel "$DEPLOY_GROUP"; fi
if [[ -d $DEPLOY_HOME ]]; then
    rm -f -- "$DEPLOY_HOME/.bashrc" "$DEPLOY_HOME/bin/rsync" "$DEPLOY_HOME/bin/deploy-command" \
        "$DEPLOY_HOME/bin/plainsay_release_retention.py"
    for directory in "$DEPLOY_HOME/bin" "$DEPLOY_HOME/.ssh" "$DEPLOY_HOME"; do
        if [[ -d $directory ]]; then rmdir -- "$directory"; fi
    done
fi
archive=$(mktemp -d /var/backups/plainsay-deploy-restored.XXXXXX)
mv -T -- "$BACKUP" "$archive"
printf 'OVH access removed. Baseline archived at %s\n' "$archive"
