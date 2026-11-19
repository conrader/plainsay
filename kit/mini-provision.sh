#!/bin/bash
# Disable tracing before a token can enter the shell.
set +x
set -euo pipefail
umask 077
# shellcheck source=kit/mini-common.sh
source "$(dirname "$0")/mini-common.sh"

usage() {
    printf '%s\n' \
        "Usage: $0 --key-only" \
        "       $0 [--check] 'codex-server ssh-ed25519 HOST_PUBLIC_KEY' SHA256:FINGERPRINT" \
        'Set OVH_HOST to the verified Tailscale name or address if it differs from vps-ovh-1-ts.'
}
mode=provision
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --key-only) mode=key; shift ;;
    --check) mode=check; shift ;;
    --) shift ;;
esac
if [[ $mode == key ]]; then
    [[ $# == 0 ]] || { usage >&2; exit 2; }
else
    [[ $# == 2 && $1 != -* ]] || { usage >&2; exit 2; }
fi
check_mini
check_file "$DEPLOY_KEY"
check_file "$DEPLOY_KEY.pub"

begin_changes() {
    lock_mini
    trap 'rm -f -- "$LOCK_DIR/config" "$LOCK_DIR/pin"; rmdir -- "$LOCK_DIR"' EXIT
}

read_deploy_key() {
    [[ -f $DEPLOY_KEY && $(stat -f '%Lp' "$DEPLOY_KEY") == 600 ]] ||
        die "Expected a mode-600 Ed25519 key at $DEPLOY_KEY."
    public_key=$(ssh-keygen -y -P '' -f "$DEPLOY_KEY" 2>/dev/null) ||
        die 'The deploy key must be readable without a passphrase.'
    [[ $public_key == 'ssh-ed25519 '* ]] || die 'The deploy key must be Ed25519.'
}

install_deploy_key() {
    if [[ ! -f $DEPLOY_KEY ]]; then
        [[ ! -e $DEPLOY_KEY.pub ]] || die 'A public key already exists without its private key.'
        ssh-keygen -q -t ed25519 -N '' -C 'plainsay-nightly@mini-m4' -f "$DEPLOY_KEY" >&2
    fi
    chmod 600 -- "$DEPLOY_KEY"
    read_deploy_key
    printf '%s\n' "$public_key" > "$DEPLOY_KEY.pub"
    printf '%s\n' "$public_key"
}

if [[ $mode == key ]]; then
    begin_changes
    install_deploy_key
    exit 0
fi

ovh_host=${OVH_HOST:-vps-ovh-1-ts}
[[ $ovh_host =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] ||
    die 'OVH_HOST must be the verified OVH hostname or IPv4 address.'
[[ $1 != *$'\n'* && $1 != *$'\r'* && $2 =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] ||
    die 'Supply one host key line and its independently verified SHA256 fingerprint.'
read -r alias algorithm blob _ <<< "$1"
[[ $alias == codex-server && $algorithm == ssh-ed25519 && $blob =~ ^[A-Za-z0-9+/]+={0,2}$ ]] ||
    die 'The pin must begin with codex-server ssh-ed25519.'
pin="$alias $algorithm $blob"
fingerprint=$(printf '%s\n' "$pin" | ssh-keygen -E sha256 -lf /dev/stdin 2>/dev/null) ||
    die 'Invalid OVH host public key.'
read -r _ actual_fingerprint _ <<< "$fingerprint"
[[ $actual_fingerprint == "$2" ]] || die 'OVH host key fingerprint mismatch.'
check_file "$SSH_CONFIG"
check_file "$PIN_FILE"

write_host_block() {
    cat <<BLOCK
$BEGIN_MARK
Host codex-server
    HostName $ovh_host
    HostKeyAlias codex-server
    Port 22
    User plainsay-deploy
    IdentityFile ~/.ssh/plainsay_deploy
    IdentitiesOnly yes
    IdentityAgent none
    AddKeysToAgent no
    UserKnownHostsFile ~/.ssh/plainsay_deploy_known_hosts
    GlobalKnownHostsFile /dev/null
    KnownHostsCommand none
    HostKeyAlgorithms ssh-ed25519
    StrictHostKeyChecking yes
    VerifyHostKeyDNS no
    UpdateHostKeys no
    BatchMode yes
    PubkeyAuthentication yes
    PreferredAuthentications publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    ForwardAgent no
    ClearAllForwardings yes
    ProxyCommand none
    ProxyJump none
    ControlMaster no
    ControlPath none
    ControlPersist no
    CanonicalizeHostname no
    RemoteCommand none
    PermitLocalCommand no
    RequestTTY no
    SessionType default
    ConnectTimeout 15
Host *
$END_MARK
BLOCK
}

check_ssh_config() {
    local effective
    effective=$(ssh "$@" -G codex-server </dev/null 2>/dev/null) ||
        die 'Could not read SSH configuration.'
    awk -v host="$ovh_host" -v pin="$PIN_FILE" -v identity="$DEPLOY_KEY" '
        $1 == "hostname" && tolower($2) == tolower(host) { hostname = 1 }
        $0 == "user plainsay-deploy" { user = 1 }
        $0 == "port 22" { port = 1 }
        $0 == "hostkeyalias codex-server" { alias = 1 }
        $0 == "hostkeyalgorithms ssh-ed25519" { algo = 1 }
        $0 == "identitiesonly yes" { only = 1 }
        $0 == "identityagent none" { agent = 1 }
        $1 == "identityfile" {
            keys++
            if (substr($0, 14) == identity || $2 == "~/.ssh/plainsay_deploy") key = 1
        }
        $1 == "userknownhostsfile" {
            path = substr($0, 20)
            if (path == pin || path == "~/.ssh/plainsay_deploy_known_hosts") userpin = 1
        }
        $0 == "globalknownhostsfile /dev/null" { globalpin = 1 }
        /^stricthostkeychecking (yes|true)$/ { strict = 1 }
        /^verifyhostkeydns (no|false)$/ { dns = 1 }
        /^(proxy(command|jump)|knownhostscommand|controlpath) / && $2 != "none" { bypass = 1 }
        END {
            exit !(hostname && user && port && alias && algo && only && agent &&
                   keys == 1 && key && userpin && globalpin && strict && dns && !bypass)
        }
    ' <<< "$effective" || die 'Existing SSH settings conflict with the pinned codex-server profile.'
}

verify_ssh() {
    [[ -f $PIN_FILE && $(cat "$PIN_FILE") == "$pin" ]] || die 'Installed OVH host key is missing or differs.'
    check_ssh_config
    ssh -o BatchMode=yes -o StrictHostKeyChecking=yes codex-server \
        'test -w /var/www/plainsay-updates && test -w /var/www/plainsay-updates/releases && test -w /var/www/plainsay-app' >/dev/null ||
        die 'The pinned OVH SSH login or document root write check failed.'
}

if [[ $mode == provision ]]; then
    begin_changes
    if [[ -e $PIN_FILE && $(cat "$PIN_FILE") != "$pin" ]]; then
        die 'The existing host pin differs. Confirm key rotation before replacing it.'
    fi
    if [[ -f $SSH_CONFIG ]]; then
        strip_ssh_block "$SSH_CONFIG" > "$LOCK_DIR/config" || die 'Malformed managed SSH config block.'
    else
        : > "$LOCK_DIR/config"
    fi
    { write_host_block; cat "$LOCK_DIR/config"; } > "$LOCK_DIR/pin"
    check_ssh_config -F "$LOCK_DIR/pin"
    install_deploy_key
    mv -f -- "$LOCK_DIR/pin" "$LOCK_DIR/config"
    printf '%s\n' "$pin" > "$LOCK_DIR/pin"
    mv -f -- "$LOCK_DIR/pin" "$PIN_FILE"
    mv -f -- "$LOCK_DIR/config" "$SSH_CONFIG"
else
    read_deploy_key
fi
verify_ssh

for tool in gh git security; do
    command -v "$tool" >/dev/null || die "Install or enable $tool on mini-m4."
done

has_file_token() {
    [[ -f $GH_CONFIG_DIR/hosts.yml ]] &&
        grep -Eq '^[[:space:]]*(oauth_token|refresh_token):' "$GH_CONFIG_DIR/hosts.yml"
}

verify_github() {
    local active_token user repo
    if has_file_token; then
        die 'GitHub CLI used file storage. Run mini-reverse.sh and unlock the login Keychain.'
    fi
    security find-generic-password -s "gh:$GH_HOST" -a "$GH_USER" >/dev/null 2>&1 ||
        die 'The GitHub CLI Keychain item is unavailable.'
    active_token=$(gh auth token --hostname "$GH_HOST" 2>/dev/null) ||
        die 'The GitHub CLI credential is unavailable.'
    [[ $active_token =~ ^github_pat_[A-Za-z0-9_]+$ ]] || die 'Expected a fine-grained GitHub PAT.'
    unset active_token
    user=$(gh api --hostname "$GH_HOST" user --jq .login 2>/dev/null) ||
        die 'Cannot verify the authenticated GitHub user.'
    [[ $user == "$GH_USER" ]] || die "GitHub CLI must authenticate as $GH_USER."
    for repo in conrader/plainsay conrader/homebrew-plainsay; do
        [[ $(gh api --hostname "$GH_HOST" "repos/$repo" --jq .permissions.push 2>/dev/null) == true ]] ||
            die "$GH_USER push permission could not be confirmed for $repo."
    done
}

[[ ! -L $GH_CONFIG_DIR ]] || die "Inspect $GH_CONFIG_DIR before continuing."
check_file "$GH_CONFIG_DIR/.managed"
check_file "$GIT_CONFIG_GLOBAL"
check_file "$GH_CONFIG_DIR/hosts.yml"
if [[ $mode == provision ]]; then
    if [[ ! -f $GH_CONFIG_DIR/.managed ]]; then
        [[ ! -e $GH_CONFIG_DIR ]] || die "Unmanaged GitHub CLI directory exists at $GH_CONFIG_DIR."
        if security find-generic-password -s "gh:$GH_HOST" >/dev/null 2>&1; then
            die "An existing gh Keychain item for $GH_HOST would be affected. Use the dedicated login."
        fi
        mkdir -m 700 -- "$GH_CONFIG_DIR"
        : > "$GH_CONFIG_DIR/.managed"
    fi
    [[ -O $GH_CONFIG_DIR && $(stat -f '%Lp' "$GH_CONFIG_DIR") == 700 ]] ||
        die 'The release GitHub CLI directory must be yours and mode 700.'
    use_release_auth
    if [[ -t 0 ]]; then printf 'Paste the fine-grained PAT and press Return. Input is hidden.\n' >&2; fi
    IFS= read -rs pat || [[ -n ${pat:-} ]] || die 'Expected a fine-grained PAT on stdin.'
    if [[ -t 0 ]]; then printf '\n' >&2; fi
    [[ $pat =~ ^github_pat_[A-Za-z0-9_]+$ ]] || die 'Expected a fine-grained PAT on stdin.'

    # Check the account before gh can write a Keychain item for it. curl gets
    # the authorization header on stdin and does not read ~/.curlrc.
    login=$(printf 'Authorization: Bearer %s\n' "$pat" |
        curl --disable --silent --fail --max-time 20 --proto '=https' --header @- \
            https://api.github.com/user 2>/dev/null |
        plutil -extract login raw -o - - 2>/dev/null) || die 'Could not validate the PAT account.'
    [[ $login == "$GH_USER" ]] || die "PAT must belong to $GH_USER."
    login_ok=1
    printf '%s\n' "$pat" |
        gh auth login --hostname "$GH_HOST" --git-protocol https --with-token >/dev/null 2>&1 || login_ok=0
    unset pat
    if has_file_token; then
        gh auth logout --hostname "$GH_HOST" --user "$GH_USER" >/dev/null 2>&1 ||
            die 'Keychain storage failed. Run mini-reverse.sh and revoke this PAT.'
        die 'Keychain storage failed. Unlock the login Keychain before retrying.'
    fi
    [[ $login_ok == 1 ]] || die 'GitHub CLI login failed. Check the token and the unlocked login Keychain.'
    gh auth setup-git --hostname "$GH_HOST" >/dev/null 2>&1 || die 'Could not set up the Git credential helper.'
    verify_github
    github_id=$(gh api --hostname "$GH_HOST" user --jq .id 2>/dev/null) ||
        die 'Cannot look up the GitHub commit identity.'
    [[ $github_id =~ ^[1-9][0-9]*$ ]] || die 'Invalid GitHub user ID.'
    git config --global user.name 'Plainsay Release'
    git config --global user.email "$github_id+$GH_USER@users.noreply.github.com"
    chmod 600 -- "$GIT_CONFIG_GLOBAL"
else
    [[ -f $GH_CONFIG_DIR/.managed && -O $GH_CONFIG_DIR &&
        $(stat -f '%Lp' "$GH_CONFIG_DIR") == 700 ]] ||
        die 'Release GitHub CLI configuration is missing or has unsafe permissions.'
    use_release_auth
    verify_github
fi
[[ $(git config --global --get user.name) == 'Plainsay Release' &&
    $(git config --global --get user.email) == *"+$GH_USER@users.noreply.github.com" &&
    $(git config --global --get credential.https://github.com.helper) == *' auth git-credential' ]] ||
    die 'Release Git identity or credential helper is missing.'
printf 'Verified pinned OVH SSH, GitHub access and release Git configuration.\n' >&2
