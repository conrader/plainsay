#!/bin/bash
set -euo pipefail
umask 077
# shellcheck source=kit/ovh-common.sh
source "$(dirname "$0")/ovh-common.sh"

usage() {
    printf 'Usage: %s [--dry-run] "ssh-ed25519 PUBLIC_KEY [comment]"\n' "$0"
}

dry_run=0
source_pin='from="100.106.213.49",'
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry_run=1 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) usage >&2; exit 2 ;;
        *) break ;;
    esac
    shift
done
[[ $# == 1 ]] || { usage >&2; exit 2; }
[[ $1 != *$'\n'* && $1 != *$'\r'* ]] || die 'Supply one Ed25519 public key line.'
read -r algorithm blob _ <<< "$1"
[[ $algorithm == ssh-ed25519 && $blob =~ ^[A-Za-z0-9+/]+={0,2}$ ]] ||
    die 'Supply one Ed25519 public key line.'
pubkey="$algorithm $blob"
require_tools ssh-keygen
printf '%s\n' "$pubkey" | ssh-keygen -l -E sha256 -f /dev/stdin >/dev/null 2>&1 ||
    die 'Invalid Ed25519 public key.'

# The forced command admits only the release, site and probe commands.
key_options="restrict,command=\"$DEPLOY_HOME/bin/deploy-command\""

if [[ $dry_run == 1 ]]; then
    printf '%s\n' \
        'Check OVH tools: rsync sha256sum mktemp xmllint and POSIX ACL utilities.' \
        "Stop unless / and $UPDATES each have at least 8 GiB free." \
        "Back up existing ACLs, owners and groups to $BACKUP." \
        "Create locked system user $DEPLOY_USER and shared group $DEPLOY_GROUP for it and $LEGACY_USER." \
        "Grant shared directory access to $UPDATES, its releases and backup directories, and the $SITE tree." \
        "Install the site rsync receiver and forced command under $DEPLOY_HOME/bin and verify deploy/nginx access." \
        "Install one authorized key with ${source_pin}${key_options} in $DEPLOY_HOME/.ssh/authorized_keys."
    exit 0
fi

require_tools flock rsync sha256sum mktemp xmllint getfacl setfacl runuser useradd usermod groupadd df python3 curl
lock_ovh
check_disk_free
check_tree "$UPDATES"
check_tree "$UPDATES/releases"
check_tree "$SITE"
[[ $(stat -c %d -- "$UPDATES") == "$(stat -c %d -- "$UPDATES/releases")" ]] ||
    die 'The update root and releases directory must support same-filesystem renames.'
[[ -x /usr/bin/rsync ]] || die 'The receiver needs /usr/bin/rsync.'
id "$LEGACY_USER" >/dev/null 2>&1 || die "Existing publisher $LEGACY_USER is missing."
nginx_uid=$(id -u "$NGINX_USER") || die "Missing nginx user $NGINX_USER."
for file in "$UPDATES/appcast.xml" "$UPDATES/releases/Plainsay-latest.dmg" "$SITE/index.html"; do
    if [[ ! -f $file ]] || ! real_path "$file"; then
        die "Expected a regular file at $file."
    fi
    runuser -u "$NGINX_USER" -- test -r "$file" || die "nginx cannot read $file before setup."
done
# A default ACL would override the release script's umask when it creates
# .release-backups. The stage and individual backups use mktemp's 0700.
update_acl=$(getfacl -cp -- "$UPDATES")
[[ $update_acl != *default:* ]] || die "Review the existing default ACL on $UPDATES before setup."

if [[ ! -e $BACKUP && ! -L $BACKUP ]]; then
    if getent passwd "$DEPLOY_USER" >/dev/null || getent group "$DEPLOY_GROUP" >/dev/null ||
        [[ -e $DEPLOY_HOME || -L $DEPLOY_HOME ]]; then
        die 'The deploy account, group or home already exists without a kit backup.'
    fi

    staging=$(mktemp -d /var/backups/.plainsay-deploy.XXXXXX)
    trap 'rm -rf -- "$staging"' EXIT
    {
        printf '%s\0' "$UPDATES" "$UPDATES/releases" "$UPDATES/appcast.xml" "$UPDATES/releases/Plainsay-latest.dmg"
        if [[ -e $UPDATES/.release-backups || -L $UPDATES/.release-backups ]]; then
            check_tree "$UPDATES/.release-backups"
            printf '%s\0' "$UPDATES/.release-backups"
        fi
        find -P "$SITE" -type d -print0
    } > "$staging/paths"
    stat -c '%u:%g' -- "$UPDATES" "$UPDATES/releases" "$SITE" > "$staging/owners"
    index=0
    while IFS= read -r -d '' path; do
        getfacl -pn -- "$path" > "$staging/acl.$index"
        index=$((index + 1))
    done < "$staging/paths"
    mv -T -- "$staging" "$BACKUP"
    trap - EXIT
else
    assert_backup
fi

if [[ -e $DEPLOY_HOME || -L $DEPLOY_HOME ]]; then
    check_tree "$DEPLOY_HOME"
    [[ $(stat -c '%u:%a' -- "$DEPLOY_HOME") == 0:755 ]] ||
        die 'Deploy home must be root-owned and mode 755.'
fi
getent group "$DEPLOY_GROUP" >/dev/null || groupadd --system "$DEPLOY_GROUP"
group_entry=$(getent group "$DEPLOY_GROUP")
IFS=: read -r _ _ deploy_gid members <<< "$group_entry"
[[ -z $members || $members == "$LEGACY_USER" ]] || die 'Unexpected shared group membership.'
if [[ -f $BACKUP/gid ]]; then
    [[ $(cat "$BACKUP/gid") == "$deploy_gid" ]] || die 'Deploy group ID changed.'
else
    printf '%s\n' "$deploy_gid" > "$BACKUP/gid"
fi

id "$DEPLOY_USER" >/dev/null 2>&1 ||
    useradd --system --no-create-home --home-dir "$DEPLOY_HOME" --gid "$DEPLOY_GROUP" --shell /bin/bash "$DEPLOY_USER"
IFS=: read -r _ _ deploy_uid primary_gid _ home shell <<< "$(getent passwd "$DEPLOY_USER")"
shadow=$(getent shadow "$DEPLOY_USER")
[[ $home == "$DEPLOY_HOME" && $shell == /bin/bash && $primary_gid == "$deploy_gid" &&
    $(id -G "$DEPLOY_USER") == "$deploy_gid" && ${shadow#*:} == '!'* ]] ||
    die 'Deploy account differs from the locked account created by this kit.'
if [[ -f $BACKUP/uid ]]; then
    [[ $(cat "$BACKUP/uid") == "$deploy_uid" ]] || die 'Deploy account ID changed.'
else
    printf '%s\n' "$deploy_uid" > "$BACKUP/uid"
fi
[[ $members == "$LEGACY_USER" ]] || usermod -a -G "$DEPLOY_GROUP" "$LEGACY_USER"

grant_group "$UPDATES" rwx 0 "$deploy_gid" "$nginx_uid"
grant_group "$UPDATES/releases" rwx 0 "$deploy_gid" "$nginx_uid"
grant_group "$UPDATES/appcast.xml" r-- 0 "$deploy_gid" "$nginx_uid"
grant_group "$UPDATES/releases/Plainsay-latest.dmg" r-- 0 "$deploy_gid" "$nginx_uid"
if [[ -e $UPDATES/.release-backups || -L $UPDATES/.release-backups ]]; then
    check_tree "$UPDATES/.release-backups"
else
    : > "$BACKUP/created-update-backups"
    mkdir -m 0700 -- "$UPDATES/.release-backups"
fi
grant_group "$UPDATES/.release-backups" rwx 0 "$deploy_gid" "$nginx_uid"

# Materialize the listing so a find failure cannot be lost in process substitution.
find -P "$SITE" -type d -print0 > "$BACKUP/site.current"
while IFS= read -r -d '' path; do
    grant_group "$path" rwx 1 "$deploy_gid" "$nginx_uid"
done < "$BACKUP/site.current"

for directory in "$UPDATES" "$UPDATES/releases" "$UPDATES/.release-backups" "$SITE"; do
    if ! runuser -u "$DEPLOY_USER" -- test -w "$directory" ||
        ! runuser -u "$DEPLOY_USER" -- test -x "$directory"; then
        die "$DEPLOY_USER cannot write and traverse $directory."
    fi
done
for file in "$UPDATES/appcast.xml" "$UPDATES/releases/Plainsay-latest.dmg"; do
    runuser -u "$DEPLOY_USER" -- test -r "$file" || die "$DEPLOY_USER cannot back up $file."
    runuser -u "$NGINX_USER" -- test -r "$file" || die "nginx cannot read $file."
done
runuser -u "$NGINX_USER" -- test -r "$SITE/index.html" || die 'nginx cannot read the website.'

install -d -o root -g root -m 0755 -- "$DEPLOY_HOME" "$DEPLOY_HOME/bin"
install -d -o root -g "$DEPLOY_GROUP" -m 0750 -- "$DEPLOY_HOME/.ssh"
install -o root -g root -m 0755 -- "$(dirname "$0")/ovh-site-rsync.sh" "$DEPLOY_HOME/bin/rsync"
install -o root -g root -m 0644 -- "$(dirname "$0")/../Scripts/plainsay_release_retention.py" "$DEPLOY_HOME/bin/plainsay_release_retention.py"
install -o root -g root -m 0755 -- "$(dirname "$0")/ovh-deploy-command.sh" "$DEPLOY_HOME/bin/deploy-command"
# shellcheck disable=SC2016 # Expand PATH when the remote Bash shell starts.
printf 'export PATH="%s/bin:$PATH"\n' "$DEPLOY_HOME" > "$DEPLOY_HOME/.bashrc"
chmod 0644 -- "$DEPLOY_HOME/.bashrc"
# sshd opens this file with the login user's privileges. The group can read
# the public key, while only root can change it.
keyfile=$(mktemp "$DEPLOY_HOME/.ssh/.authorized_keys.XXXXXX")
trap 'rm -f -- "$keyfile"' EXIT
printf '%s%s %s\n' "$source_pin" "$key_options" "$pubkey" > "$keyfile"
chown "root:$DEPLOY_GROUP" -- "$keyfile"
chmod 0640 -- "$keyfile"
mv -f -- "$keyfile" "$DEPLOY_HOME/.ssh/authorized_keys"
printf 'OVH provisioned. Baseline ACL and ownership backup: %s\n' "$BACKUP"
