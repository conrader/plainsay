#!/bin/bash
set +x
set -euo pipefail
umask 077
# shellcheck source=kit/mini-common.sh
source "$(dirname "$0")/mini-common.sh"

case "${1:-}" in
    -h|--help) printf 'Usage: %s\n' "$0"; exit 0 ;;
esac
[[ $# == 0 ]] || die 'This script takes no arguments. See --help.'
check_mini
[[ -d $SSH_DIR ]] || exit 0
lock_mini
trap 'rm -f -- "$LOCK_DIR/config"; rmdir -- "$LOCK_DIR"' EXIT
for file in "$SSH_CONFIG" "$DEPLOY_KEY" "$DEPLOY_KEY.pub" "$PIN_FILE"; do
    check_file "$file"
done
if [[ -f $SSH_CONFIG ]] && grep -Fxq -e "$BEGIN_MARK" -e "$END_MARK" "$SSH_CONFIG"; then
    strip_ssh_block "$SSH_CONFIG" > "$LOCK_DIR/config" || die 'Malformed managed SSH config block.'
    mv -f -- "$LOCK_DIR/config" "$SSH_CONFIG"
fi
rm -f -- "$DEPLOY_KEY" "$DEPLOY_KEY.pub" "$PIN_FILE"

[[ ! -L $GH_CONFIG_DIR ]] || die "Inspect $GH_CONFIG_DIR before continuing."
if [[ -e $GH_CONFIG_DIR ]]; then
    check_file "$GH_CONFIG_DIR/.managed"
    [[ -f $GH_CONFIG_DIR/.managed ]] || die "Unmanaged GitHub CLI directory at $GH_CONFIG_DIR."
    check_file "$GH_CONFIG_DIR/hosts.yml"
    use_release_auth
    if [[ -f $GH_CONFIG_DIR/hosts.yml ]] && grep -q '^github\.com:' "$GH_CONFIG_DIR/hosts.yml"; then
        gh auth logout --hostname "$GH_HOST" --user "$GH_USER" >/dev/null 2>&1 ||
            die 'GitHub logout failed. Unlock the Keychain, revoke the PAT and retry.'
    fi
    if security find-generic-password -s "gh:$GH_HOST" -a "$GH_USER" >/dev/null 2>&1; then
        die 'Remove the leftover gh:github.com Keychain item for conrader before retrying.'
    fi
    rm -rf -- "$GH_CONFIG_DIR"
fi
printf 'Local release credentials removed. Revoke the PAT in GitHub settings.\n'
