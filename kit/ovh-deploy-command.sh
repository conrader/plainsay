#!/bin/bash
# Forced command for the plainsay-deploy key. It runs only the exact remote
# commands sent by Scripts/release.sh, Scripts/deploy-site.sh and the kit's
# write probe. Uploads stream directly into a validated release stage.
set -euo pipefail
export LC_ALL=C
export PATH=/usr/bin:/bin
umask 077
UPDATES=/var/www/plainsay-updates
SITE=/var/www/plainsay-app
RECEIVER=/var/lib/plainsay-deploy/bin/rsync
RETENTION=/var/lib/plainsay-deploy/bin/release-retention
MIN_FREE_KIB=$((8 * 1024 * 1024))

STAGE_RE="$UPDATES/\\.release-stage\\.[A-Za-z0-9]{6}"
VERSION_RE='[0-9]+\.[0-9]+\.[0-9]+'
PACKAGE_RE="Plainsay-$VERSION_RE\\.(zip|dmg)|appcast\\.xml"
CHECKSUM_RE="^sha256sum '($STAGE_RE)/($PACKAGE_RE)'\$"
UPLOAD_RE="^cat > '($STAGE_RE)/($PACKAGE_RE)'\$"
REMOVE_RE="^rm -rf '($STAGE_RE)'\$"
SHA_RE='[a-f0-9]{64}'
BACKUP_RE="v$VERSION_RE\\.[A-Za-z0-9_]{8}\\.tar"
RECEIPT_RE="$BACKUP_RE $SHA_RE $SHA_RE $SHA_RE $SHA_RE"
RETENTION_RE="^$RETENTION (check|backup $VERSION_RE|activate $VERSION_RE \\.release-stage\\.[A-Za-z0-9]{6} $RECEIPT_RE|prune $VERSION_RE $RECEIPT_RE)\$"

# Succeeds when $1 is a shell command this key may run verbatim.
allowed_shell() {
    local command=$1
    case "$command" in
        "test -w $UPDATES && test -w $UPDATES/releases && test -w $SITE" |\
        "mktemp -d '$UPDATES/.release-stage.XXXXXX'")
            return 0 ;;
    esac
    [[ $command =~ $CHECKSUM_RE || $command =~ $REMOVE_RE || $command =~ $UPLOAD_RE ||
        $command =~ $RETENTION_RE ]]
}

# Succeeds when $@ is an rsync push into the website root.
allowed_rsync() {
    local count=$# argument
    (( count >= 5 )) || return 1
    [[ ( $1 == rsync || $1 == "$RECEIVER" ) && $2 == --server ]] || return 1
    # The optional -e argument is rsync's server compatibility suffix.
    [[ $3 =~ ^-[nvlogDtprz]+(e\.[iLsfxCIvu]*)?$ ]] || return 1
    [[ ${*: -2:1} == . ]] || return 1
    [[ ${!count} == "$SITE" || ${!count} == "$SITE/" ]] || return 1
    for argument in "${@:4:count-5}"; do
        case "$argument" in
            --delete|--delete-before|--delete-during|--delete-delay|--delete-after) ;;
            --no-o|--no-g|--no-owner|--no-group|--no-perms|--omit-dir-times) ;;
            --log-format=%i|--log-format=%i%I) ;;
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

require_space() {
    if ! enough_space; then
        printf 'plainsay-deploy: cannot confirm 8 GiB free on / and the update filesystem.\n' >&2
        exit 1
    fi
}

upload() (
    stage=$1 package=$2
    cd -P -- "$stage" && [[ $PWD == "$stage" && -O . ]] || exit 126
    require_space
    # Keep incomplete uploads private. A retry replaces only the named file.
    tmp=$(mktemp -- .upload.XXXXXX)
    trap 'rm -f -- "$tmp"' EXIT
    cat > "$tmp"
    mv -fT -- "$tmp" "$package"
)

main() {
    local command=${SSH_ORIGINAL_COMMAND:-} words
    if [[ $command == 'rsync --server '* || $command == "$RECEIVER --server "* ]]; then
        if [[ $command != *$'\n'* ]]; then
            IFS=' ' read -r -a words <<< "$command"
            if allowed_rsync "${words[@]}" && [[ -d $SITE && $(realpath -e -- "$SITE") == "$SITE" ]]; then
                exec "$RECEIVER" "${words[@]:1:${#words[@]}-3}" \
                    --no-D --munge-links --safe-links "${words[@]: -2}"
            fi
        fi
    elif [[ $command =~ $UPLOAD_RE ]]; then
        upload "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return
    elif [[ $command =~ $RETENTION_RE ]]; then
        IFS=' ' read -r -a words <<< "$command"
        if [[ ${words[1]} == backup ]]; then require_space; fi
        exec "$RETENTION" "${words[@]:1}"
    elif allowed_shell "$command"; then
        if [[ $command == "mktemp -d '$UPDATES/.release-stage.XXXXXX'" ]]; then
            require_space
        fi
        exec /bin/bash -c "$command"
    fi
    printf 'plainsay-deploy: command not permitted.\n' >&2
    exit 126
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main; fi
