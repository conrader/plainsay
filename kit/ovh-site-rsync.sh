#!/bin/bash
# Installed as rsync in the deploy account's PATH. The legacy SSH
# publisher can use the same receiver by adding this directory to its PATH.
set -euo pipefail

# rsync sends "--server [options] . DEST" for a push. Other rsync commands,
# including sends, have their original behavior.
if [[ ${1:-} == --server && " $* " != *' --sender '* ]]; then
    case "${!#}" in
        /var/www/plainsay-app|/var/www/plainsay-app/)
            # Place these after the transmitted -p and -t flags.
            set -- "$@" --no-perms --omit-dir-times --omit-link-times --chmod=Dg+rwx,Fg+rw
            ;;
    esac
fi
exec /usr/bin/rsync "$@"
