#!/bin/bash
# shellcheck disable=SC2034 # Constants are consumed by the mini entry points.
SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
DEPLOY_KEY="$SSH_DIR/plainsay_deploy"
PIN_FILE="$SSH_DIR/plainsay_deploy_known_hosts"
GH_CONFIG_DIR="$SSH_DIR/plainsay-release-gh"
GIT_CONFIG_GLOBAL="$GH_CONFIG_DIR/gitconfig"
GH_HOST=github.com
GH_USER=conrader
LOCK_DIR="$SSH_DIR/.plainsay-release.lock"
BEGIN_MARK='# BEGIN Plainsay nightly deployment'
END_MARK='# END Plainsay nightly deployment'

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

check_mini() {
    [[ $(uname -s) == Darwin && $(uname -m) == arm64 && $(id -un) == konrad ]] ||
        die 'Run on Apple silicon macOS as konrad.'
    [[ ! -L $SSH_DIR && ( ! -e $SSH_DIR || -d $SSH_DIR ) ]] ||
        die "Expected a regular directory at $SSH_DIR."
}

check_file() {
    [[ ! -L $1 && ( ! -e $1 || ( -f $1 && -O $1 ) ) ]] || die "Inspect $1 before continuing."
}

lock_mini() {
    mkdir -p -- "$SSH_DIR"
    mkdir -m 700 -- "$LOCK_DIR" || die "Setup is in progress. Inspect $LOCK_DIR."
    trap 'rmdir -- "$LOCK_DIR"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

use_release_auth() {
    unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_DEBUG DEBUG GH_FORCE_TTY
    unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG
    export GH_CONFIG_DIR GH_HOST GIT_CONFIG_GLOBAL GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1
}

strip_ssh_block() {
    awk -v begin="$BEGIN_MARK" -v end="$END_MARK" '
        $0 == begin { if (found++) exit 1; inside = 1; next }
        $0 == end { if (!inside) exit 1; inside = 0; next }
        !inside { print }
        END { if (inside) exit 1 }
    ' "${1:-/dev/null}"
}
