#!/bin/bash
# Forced command for the plainsay-deploy key. It runs only the exact remote
# commands sent by Scripts/release.sh, Scripts/deploy-site.sh and the kit's
# write probe, plus SFTP for scp uploads. Everything else is refused.
set -euo pipefail
export LC_ALL=C
UPDATES=/var/www/plainsay-updates
SITE=/var/www/plainsay-app
RECEIVER=/var/lib/plainsay-deploy/bin/rsync
SFTP_SERVER=/usr/lib/openssh/sftp-server
MIN_FREE_KIB=$((8 * 1024 * 1024))

STAGE_RE="$UPDATES/\\.release-stage\\.[A-Za-z0-9]{6}"
VERSION_RE='[0-9]+\.[0-9]+\.[0-9]+'
PACKAGE_RE="Plainsay-$VERSION_RE\\.(zip|dmg)|appcast\\.xml"
CHECKSUM_RE="^sha256sum '($STAGE_RE)/($PACKAGE_RE)'\$"
REMOVE_RE="^rm -rf '($STAGE_RE)'\$"
ACTIVATE_RE="^set -eu"$'\n'"chmod a\\+r '($STAGE_RE)/(Plainsay-$VERSION_RE\\.zip)' '$STAGE_RE/(Plainsay-$VERSION_RE\\.dmg)' "

backup_template() {
    local template
    template=$(cat <<'EOF'
set -eu
umask 077
mkdir -p '@U@/.release-backups'
backup=$(mktemp -d '@U@/.release-backups/v@V@.XXXXXX')
cp '@U@/appcast.xml' "$backup/appcast.xml"
cp '@U@/releases/Plainsay-latest.dmg' "$backup/Plainsay-latest.dmg"
printf '%s\n' "$backup"
EOF
)
    template=${template//@U@/$UPDATES}
    printf '%s' "${template//@V@/$1}"
}

activate_template() {
    local template
    template=$(cat <<'EOF'
set -eu
chmod a+r '@S@/@Z@' '@S@/@D@' '@S@/appcast.xml'
mv '@S@/@Z@' '@U@/releases/@Z@'
mv '@S@/@D@' '@U@/releases/Plainsay-latest.dmg'
mv '@S@/appcast.xml' '@U@/appcast.xml'
rmdir '@S@'
EOF
)
    template=${template//@S@/$1}
    template=${template//@Z@/$2}
    template=${template//@D@/$3}
    printf '%s' "${template//@U@/$UPDATES}"
}

# Succeeds when $1 is a shell command this key may run verbatim.
allowed_shell() {
    local command=$1 version stage zip dmg
    case "$command" in
        "test -w $UPDATES && test -w $UPDATES/releases && test -w $SITE" |\
        "mktemp -d '$UPDATES/.release-stage.XXXXXX'")
            return 0 ;;
    esac
    if [[ $command =~ $CHECKSUM_RE || $command =~ $REMOVE_RE ]]; then
        return 0
    fi
    if [[ $command =~ \.release-backups/v($VERSION_RE)\.XXXXXX ]]; then
        version=${BASH_REMATCH[1]}
        [[ $command == "$(backup_template "$version")" ]] && return 0
    fi
    if [[ $command =~ $ACTIVATE_RE ]]; then
        stage=${BASH_REMATCH[1]}
        zip=${BASH_REMATCH[2]}
        dmg=${BASH_REMATCH[3]}
        [[ $command == "$(activate_template "$stage" "$zip" "$dmg")" ]] && return 0
    fi
    return 1
}

# Succeeds when $@ is an rsync push into the website root.
allowed_rsync() {
    local count=$# argument
    (( count >= 5 )) || return 1
    [[ $1 == rsync && $2 == --server ]] || return 1
    [[ ${*: -2:1} == . ]] || return 1
    [[ ${!count} == "$SITE" || ${!count} == "$SITE/" ]] || return 1
    for argument in "${@:3:count-4}"; do
        case "$argument" in
            --delete|--delete-before|--delete-during|--delete-delay|--delete-after) ;;
            --no-o|--no-g|--no-owner|--no-group|--no-perms|--omit-dir-times) ;;
            -[A-Za-z]*) [[ $argument =~ ^-[A-Za-z][A-Za-z.]*$ ]] || return 1 ;;
            *) return 1 ;;
        esac
    done
}

# Release uploads and backups stop when / or the update root is below 8 GiB.
enough_space() {
    local path available
    for path in / "$UPDATES"; do
        available=$(df -Pk -- "$path" | awk 'NR == 2 { print $4 }') || return 1
        [[ $available =~ ^[0-9]+$ ]] && (( available >= MIN_FREE_KIB )) || return 1
    done
}

main() {
    local command=${SSH_ORIGINAL_COMMAND:-} words
    if [[ $command == "$SFTP_SERVER" || $command == internal-sftp ]]; then
        exec "$SFTP_SERVER" -P symlink,hardlink
    fi
    if [[ $command == 'rsync --server '* && $command != *$'\n'* ]]; then
        read -r -a words <<< "$command"
        if allowed_rsync "${words[@]}"; then
            exec "$RECEIVER" "${words[@]:1}"
        fi
    elif allowed_shell "$command"; then
        if [[ $command == "mktemp -d '$UPDATES/.release-stage.XXXXXX'" ||
            $command == *'.release-backups/v'* ]] && ! enough_space; then
            printf 'plainsay-deploy: STOP, less than 8 GiB free on the update host.\n' >&2
            exit 1
        fi
        exec /bin/bash -c "$command"
    fi
    printf 'plainsay-deploy: command not permitted.\n' >&2
    exit 126
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main; fi
