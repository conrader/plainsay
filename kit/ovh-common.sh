#!/bin/bash
# Shared settings for the two OVH entry points.
# shellcheck disable=SC2034
export LC_ALL=C
DEPLOY_USER=plainsay-deploy
DEPLOY_GROUP=plainsay-publish
LEGACY_USER=conrader
NGINX_USER=www-data
DEPLOY_HOME=/var/lib/plainsay-deploy
BACKUP=/var/backups/plainsay-deploy
UPDATES=/var/www/plainsay-updates
SITE=/var/www/plainsay-app
MIN_FREE_KIB=$((8 * 1024 * 1024))

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_tools() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null || die "Install $tool on OVH before proceeding."
    done
}

# Stop when / or the update root has less than 8 GiB available.
check_disk_free() {
    local path available
    for path in / "$UPDATES"; do
        available=$(df -Pk -- "$path" | awk 'NR == 2 { print $4 }')
        [[ $available =~ ^[0-9]+$ ]] || die "Could not read free space for $path."
        (( available >= MIN_FREE_KIB )) || die "STOP: less than 8 GiB free on the filesystem of $path."
    done
}

lock_ovh() {
    [[ $EUID == 0 ]] || die 'Run this operation with sudo on OVH.'
    exec 9>/run/plainsay-deploy-setup.lock
    flock -x 9
}

real_path() {
    [[ $(realpath -e -- "$1" 2>/dev/null) == "$1" ]]
}

check_tree() {
    if [[ ! -d $1 ]] || ! real_path "$1"; then
        die "Expected a real directory at $1."
    fi
}

assert_backup() {
    check_tree "$BACKUP"
    [[ $(stat -c '%u:%a' -- "$BACKUP") == 0:700 && -f $BACKUP/paths ]] ||
        die "Inspect the backup at $BACKUP before continuing."
}

# Cap pre-existing group-class entries at their effective rights before raising
# the ACL mask for the new group. This preserves other principals' access.
grant_group() {
    local path=$1 access=$2 inherit=$3 deploy_gid=$4 nginx_uid=$5 acl edits
    acl=$(getfacl -pcne -- "$path") || return 1
    edits=$(awk -v gid="$deploy_gid" -v nginx="$nginx_uid" -v access="$access" -v inherit="$inherit" '
        $1 ~ /^default:/ {
            has_default = 1
            if ($1 ~ ("^default:user:" nginx ":")) has_nginx = 1
        }
        $2 ~ /^#effective:/ && $1 !~ ("^(default:)?group:" gid ":") &&
                ($1 !~ /^default:/ || inherit) {
            sub(/:[rwx-]+$/, ":" substr($2, 12), $1)
            print $1
        }
        END {
            print "group:" gid ":" access
            if (inherit) {
                if (!has_default) print "default:user::rwx\ndefault:group::r-x\ndefault:other::r-x"
                if (!has_nginx) print "default:user:" nginx ":r-x"
                print "default:group:" gid ":rwx"
            }
        }' <<< "$acl") || return 1
    setfacl -M - -- "$path" <<< "$edits"
}
