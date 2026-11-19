#!/bin/bash
# Offline harness. Every network command resolves to a fixture.
set -euo pipefail
umask 077
cd "$(dirname "$0")"
kit=$(pwd -P)
sandbox=$(mktemp -d /tmp/plainsay-kit-test.XXXXXX)
trap 'rm -rf -- "$sandbox"' EXIT
mkdir "$sandbox/bin"
export SANDBOX_BIN="$sandbox/bin"
export REAL_SSH
REAL_SSH=$(command -v ssh)
export REAL_STAT
REAL_STAT=$(command -v stat)
export REAL_ID
REAL_ID=$(command -v id)
export FIXTURE_PAT=github_pat_fixture
export PATH="$SANDBOX_BIN:$PATH"

cat > "$SANDBOX_BIN/fixture" <<'STUB'
#!/bin/bash
set -euo pipefail
case "${0##*/}" in
    uname)
        case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) exit 99 ;; esac ;;
    id)
        if [[ $* == '-un' ]]; then echo konrad; else exec "$REAL_ID" "$@"; fi ;;
    stat)
        [[ $* == '-f %Lp '* ]] || exit 99
        exec "$REAL_STAT" -c %a -- "$3" ;;
    ssh)
        if [[ $* == *'-G codex-server' ]]; then
            config="$HOME/.ssh/config"
            if [[ $1 == -F ]]; then config=$2; fi
            "$REAL_SSH" -F "$config" -G codex-server 2>/dev/null |
                awk -v home="$HOME" '/^userknownhostsfile / { sub(/.*\//, "userknownhostsfile " home "/.ssh/") } 1'
        else
            [[ $1 == -o && $2 == BatchMode=yes && $3 == -o && $4 == StrictHostKeyChecking=yes &&
                $5 == codex-server &&
                $6 == 'test -w /var/www/plainsay-updates && test -w /var/www/plainsay-updates/releases && test -w /var/www/plainsay-app' ]] || exit 99
            printf 'write check\n' >> "$TEST_STORE/ssh"
            [[ ${BAD_SSH:-0} == 0 ]]
        fi ;;
    security)
        [[ $1 == find-generic-password && $2 == -s && $3 == gh:github.com ]] || exit 99
        [[ -f $TEST_STORE/keychain || ${EXISTING_KEYCHAIN:-0} == 1 ]] ;;
    curl)
        [[ $* == '--disable --silent --fail --max-time 20 --proto =https --header @- https://api.github.com/user' ]] || exit 99
        read -r header
        [[ $header == "Authorization: Bearer $FIXTURE_PAT" ]] || exit 99
        printf '%s\n' "${FIXTURE_ACCOUNT:-conrader}" ;;
    plutil)
        [[ $* == '-extract login raw -o - -' ]] || exit 99
        cat ;;
    gh)
        [[ $* != *"$FIXTURE_PAT"* ]] || exit 99
        printf '%s\n' "$*" >> "$TEST_STORE/gh"
        [[ $GH_CONFIG_DIR == "$HOME/.ssh/plainsay-release-gh" && ! ${GH_TOKEN+x} ]] || exit 99
        case "$*" in
            'auth login --hostname github.com --git-protocol https --with-token')
                [[ $(cat) == "$FIXTURE_PAT" ]] || exit 99
                if [[ ${FALLBACK:-0} == 1 ]]; then
                    printf 'github.com:\n  user: conrader\n  oauth_token: %s\n' "$FIXTURE_PAT" > "$GH_CONFIG_DIR/hosts.yml"
                else
                    printf 'github.com:\n  user: conrader\n' > "$GH_CONFIG_DIR/hosts.yml"
                    : > "$TEST_STORE/keychain"
                fi ;;
            'auth setup-git --hostname github.com')
                git config --global credential.https://github.com.helper '!gh auth git-credential' ;;
            'auth token --hostname github.com')
                [[ -f $TEST_STORE/keychain ]] || exit 99
                printf '%s\n' "$FIXTURE_PAT" ;;
            'auth logout --hostname github.com --user conrader')
                rm -f -- "$TEST_STORE/keychain" "$GH_CONFIG_DIR/hosts.yml" ;;
            'api --hostname github.com user --jq .login') echo conrader ;;
            'api --hostname github.com user --jq .id') echo 12345 ;;
            'api --hostname github.com repos/conrader/plainsay --jq .permissions.push') echo true ;;
            'api --hostname github.com repos/conrader/homebrew-plainsay --jq .permissions.push')
                echo "${TAP_PUSH:-true}" ;;
            *) exit 99 ;;
        esac ;;
esac
STUB
chmod +x "$SANDBOX_BIN/fixture"
for command in uname id stat ssh security curl plutil gh; do
    ln -s fixture "$SANDBOX_BIN/$command"
done

ssh-keygen -q -t ed25519 -N '' -f "$sandbox/host-test-key"
read -r host_algorithm host_blob _ < "$sandbox/host-test-key.pub"
pin="codex-server $host_algorithm $host_blob"
fingerprint=$(ssh-keygen -E sha256 -lf "$sandbox/host-test-key.pub" | awk '{print $2}')
wrong_fingerprint=SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA

passed=0
case_run() {
    local description=$1
    shift
    export HOME="$sandbox/home.$passed" TEST_STORE="$sandbox/test.$passed"
    mkdir "$HOME" "$TEST_STORE"
    "$@"
    passed=$((passed + 1))
    printf 'ok %d - %s\n' "$passed" "$description"
}

reject() {
    if "$@" > "$TEST_STORE/out" 2> "$TEST_STORE/err"; then
        printf 'Expected rejection from %s\n' "$1" >&2
        return 1
    fi
}

provision() {
    printf '%s\n' "$FIXTURE_PAT" | bash ./mini-provision.sh "$pin" "$fingerprint"
}

dry_run() {
    local public_key plan
    public_key=$(cat "$sandbox/host-test-key.pub")
    plan=$(bash ./ovh-provision.sh --dry-run "$public_key")
    [[ $plan == *'/var/backups/plainsay-deploy'* &&
        $plan == *'from="100.106.213.49",restrict'* &&
        $plan == *'command="/var/lib/plainsay-deploy/bin/deploy-command"'* &&
        $plan == *'8 GiB free'* &&
        $plan == *'/var/www/plainsay-app'* && $plan != *"$host_blob"* ]]
    plan=$(bash ./ovh-provision.sh --without-source-pin --dry-run "$public_key")
    [[ $plan == *'with restrict'* && $plan != *'from='* ]]
}

arguments() {
    bash ./mini-provision.sh --help >/dev/null
    bash ./mini-reverse.sh --help >/dev/null
    bash ./ovh-reverse.sh --help >/dev/null
    reject bash ./ovh-provision.sh --dry-run
    reject bash ./ovh-provision.sh --unknown "$pin"
    reject bash ./ovh-provision.sh --dry-run "ssh-ed25519 $host_blob"$'\nsecond line'
    reject bash ./ovh-provision.sh --dry-run 'ssh-ed25519 aGVsbG8='
    reject bash ./mini-provision.sh --check
    reject bash ./mini-provision.sh --key-only extra
    reject bash ./mini-reverse.sh extra
    reject bash ./ovh-reverse.sh extra
    [[ ! -e $HOME/.ssh ]]
}

bad_pin() {
    reject bash ./mini-provision.sh "$pin" "$wrong_fingerprint"
    grep -Fq 'fingerprint mismatch' "$TEST_STORE/err"
    reject env OVH_HOST=$'vps-ovh-1-ts\nHost *' bash ./mini-provision.sh "$pin" "$fingerprint"
    reject bash ./mini-provision.sh "other-host $host_algorithm $host_blob" "$fingerprint"
    [[ ! -e $HOME/.ssh && ! -f $TEST_STORE/ssh && ! -f $TEST_STORE/gh ]]
}

key_only() {
    local public_key
    public_key=$(bash ./mini-provision.sh --key-only)
    [[ $public_key == 'ssh-ed25519 '* && $(cat "$HOME/.ssh/plainsay_deploy.pub") == "$public_key" &&
        $("$REAL_STAT" -c %a "$HOME/.ssh/plainsay_deploy") == 600 ]]
    [[ $(bash ./mini-provision.sh --key-only) == "$public_key" &&
        ! -f $TEST_STORE/ssh && ! -f $TEST_STORE/gh ]]
}

mini_lifecycle() {
    local public_key
    mkdir "$HOME/.ssh"
    printf 'Host other-host\n    User existing\n' > "$TEST_STORE/original-config"
    cp "$TEST_STORE/original-config" "$HOME/.ssh/config"
    public_key=$(provision 2> "$TEST_STORE/err")
    [[ $public_key == 'ssh-ed25519 '* ]]
    [[ $public_key == "$(provision 2>> "$TEST_STORE/err")" ]]
    [[ $(grep -cFx '# BEGIN Plainsay nightly deployment' "$HOME/.ssh/config") == 1 ]]
    [[ $(cat "$HOME/.ssh/plainsay_deploy_known_hosts") == "$pin" ]]
    sha256sum "$HOME/.ssh/config" "$HOME/.ssh/plainsay_deploy" "$HOME/.ssh/plainsay-release-gh/"* > "$TEST_STORE/before"
    bash ./mini-provision.sh --check "$pin" "$fingerprint" > "$TEST_STORE/out" 2>> "$TEST_STORE/err"
    [[ ! -s $TEST_STORE/out ]]
    sha256sum -c "$TEST_STORE/before" >/dev/null
    [[ $(grep -F 'repos/' "$TEST_STORE/gh" | sort -u) == \
        $'api --hostname github.com repos/conrader/homebrew-plainsay --jq .permissions.push\napi --hostname github.com repos/conrader/plainsay --jq .permissions.push' ]]
    [[ $(wc -l < "$TEST_STORE/ssh") == 3 ]]
    bash ./mini-reverse.sh >/dev/null
    diff -u "$TEST_STORE/original-config" "$HOME/.ssh/config"
    [[ ! -e $HOME/.ssh/plainsay_deploy && ! -e $HOME/.ssh/plainsay_deploy_known_hosts &&
        ! -e $HOME/.ssh/plainsay-release-gh && ! -e $TEST_STORE/keychain ]]
    grep -Fxq 'auth logout --hostname github.com --user conrader' "$TEST_STORE/gh"
    bash ./mini-reverse.sh >/dev/null
    ! grep -Fq "$FIXTURE_PAT" "$TEST_STORE/gh" "$TEST_STORE/err"
}

bad_token() {
    printf 'classic-token-fixture\n' |
        reject bash ./mini-provision.sh "$pin" "$fingerprint"
    grep -Fq 'Expected a fine-grained PAT' "$TEST_STORE/err"
    printf '%s\n' "$FIXTURE_PAT" |
        reject env FIXTURE_ACCOUNT=wrong-user bash ./mini-provision.sh "$pin" "$fingerprint"
    grep -Fq 'PAT must belong to conrader' "$TEST_STORE/err"
    [[ ! -f $TEST_STORE/gh ]]
    ! grep -Fq "$FIXTURE_PAT" "$TEST_STORE/out" "$TEST_STORE/err"
}

login_fallback() {
    printf '%s\n' "$FIXTURE_PAT" |
        reject env FALLBACK=1 bash -x ./mini-provision.sh "$pin" "$fingerprint"
    grep -Fxq 'auth logout --hostname github.com --user conrader' "$TEST_STORE/gh"
    [[ ! -e $HOME/.ssh/plainsay-release-gh/hosts.yml ]]
    ! grep -Fq "$FIXTURE_PAT" "$TEST_STORE/out" "$TEST_STORE/err" "$TEST_STORE/gh"
}

push_denied() {
    printf '%s\n' "$FIXTURE_PAT" |
        reject env TAP_PUSH=false bash ./mini-provision.sh "$pin" "$fingerprint"
    grep -Fq 'push permission could not be confirmed for conrader/homebrew-plainsay' "$TEST_STORE/err"
}

conflicting_identity() {
    mkdir "$HOME/.ssh"
    printf 'Host codex-server\n    IdentityFile ~/.ssh/another-identity\n' > "$HOME/.ssh/config"
    cp "$HOME/.ssh/config" "$TEST_STORE/original-config"
    reject bash ./mini-provision.sh "$pin" "$fingerprint"
    diff -u "$TEST_STORE/original-config" "$HOME/.ssh/config"
    [[ ! -f $TEST_STORE/ssh ]]
}

existing_keychain() {
    reject env EXISTING_KEYCHAIN=1 bash ./mini-provision.sh "$pin" "$fingerprint"
    grep -Fq 'existing gh Keychain item' "$TEST_STORE/err"
    [[ ! -e $HOME/.ssh/plainsay-release-gh && ! -e $TEST_STORE/gh ]]
}

shared_receiver() {
    local dest="$TEST_STORE/site" source="$TEST_STORE/source" group
    mkdir -p "$source/older" "$source/new" "$dest/older"
    printf 'new\n' > "$source/new/index.html"
    printf 'updated\n' > "$source/older/index.html"
    printf 'delete me\n' > "$dest/older/stale.html"
    chmod 755 "$dest" "$dest/older"
    group=$("$REAL_ID" -g)
    setfacl -m "g:$group:rwx,d:g:$group:rwx" "$dest" "$dest/older"
    sed "s|/var/www/plainsay-app|$dest|g" "$kit/ovh-site-rsync.sh" > "$TEST_STORE/receiver"
    sed -e "s|/var/www/plainsay-app|$dest|g" -e "s|/var/lib/plainsay-deploy/bin/rsync|$TEST_STORE/receiver|" \
        "$kit/ovh-deploy-command.sh" > "$TEST_STORE/command"
    # Like sshd with a forced command, pass the remote command as one string.
    printf '#!/bin/bash\nshift\nSSH_ORIGINAL_COMMAND="$*" exec "%s"\n' "$TEST_STORE/command" > "$TEST_STORE/transport"
    chmod +x "$TEST_STORE/receiver" "$TEST_STORE/command" "$TEST_STORE/transport"
    rsync -az --delete --no-owner --no-group --chmod='Du=rwx,Dgo=rx,Fu=rw,Fgo=r' \
        -e "$TEST_STORE/transport" "$source/" "fixture:$dest/"
    [[ $(cat "$dest/older/index.html") == updated && $(cat "$dest/new/index.html") == new &&
        ! -e $dest/older/stale.html ]]
    [[ $("$REAL_STAT" -c %a "$dest") == 775 &&
        $("$REAL_STAT" -c %a "$dest/older") == 775 &&
        $("$REAL_STAT" -c %a "$dest/new") == 775 &&
        $("$REAL_STAT" -c %a "$dest/new/index.html") == 664 ]]
    getfacl -pcn "$dest/new" | grep -Fxq "default:group:$group:rwx"
    printf 'legacy deploy\n' > "$source/new/index.html"
    rsync -az --delete -e "$TEST_STORE/transport" "$source/" "fixture:$dest/"
    [[ $(cat "$dest/new/index.html") == 'legacy deploy' &&
        $("$REAL_STAT" -c %a "$dest/new") == 775 ]]
    mkdir "$TEST_STORE/elsewhere"
    reject rsync -az -e "$TEST_STORE/transport" "$source/" "fixture:$TEST_STORE/elsewhere/"
    reject rsync -az -e "$TEST_STORE/transport" "fixture:$dest/" "$TEST_STORE/elsewhere/"
    [[ -z $(ls -A "$TEST_STORE/elsewhere") ]]
}

forced_command() {
    local updates=/var/www/plainsay-updates version=0.2.40 stage zip dmg command
    stage="$updates/.release-stage.Ab12Cd"
    zip="Plainsay-$version.zip"
    dmg="Plainsay-$version.dmg"
    allowed() { bash -c 'source "$1"; allowed_shell "$2"' _ "$kit/ovh-deploy-command.sh" "$1"; }
    denied() { if allowed "$1"; then printf 'Unexpectedly allowed: %s\n' "$1" >&2; return 1; fi; }
    # These mirror the remote commands in Scripts/release.sh.
    allowed "mktemp -d '$updates/.release-stage.XXXXXX'"
    allowed "sha256sum '$stage/$zip'"
    allowed "sha256sum '$stage/appcast.xml'"
    allowed "rm -rf '$stage'"
    allowed "test -w $updates && test -w $updates/releases && test -w /var/www/plainsay-app"
    command="set -eu
umask 077
mkdir -p '$updates/.release-backups'
backup=\$(mktemp -d '$updates/.release-backups/v$version.XXXXXX')
cp '$updates/appcast.xml' \"\$backup/appcast.xml\"
cp '$updates/releases/Plainsay-latest.dmg' \"\$backup/Plainsay-latest.dmg\"
printf '%s\\n' \"\$backup\""
    allowed "$command"
    denied "$command"$'\nid'
    command="set -eu
chmod a+r '$stage/$zip' '$stage/$dmg' '$stage/appcast.xml'
mv '$stage/$zip' '$updates/releases/$zip'
mv '$stage/$dmg' '$updates/releases/Plainsay-latest.dmg'
mv '$stage/appcast.xml' '$updates/appcast.xml'
rmdir '$stage'"
    allowed "$command"
    denied "${command/rmdir/rm -rf}"
    denied "rm -rf '$stage'; id"
    denied "rm -rf '$updates'"
    denied "sha256sum '$stage/../../../etc/shadow'"
    denied "sudo -n chown -R conrader '$updates'"
    denied id
    reject env SSH_ORIGINAL_COMMAND=id bash "$kit/ovh-deploy-command.sh"
    reject env -u SSH_ORIGINAL_COMMAND bash "$kit/ovh-deploy-command.sh"
    grep -Fxq 'plainsay-deploy: command not permitted.' "$TEST_STORE/err"
    [[ ! -s $TEST_STORE/out ]]
    # Release staging and backups stop below 8 GiB free.
    bash -c 'source "$1"; free=$2; df() { printf "h\nfs 1 1 %s 1%% /\n" "$free"; }; enough_space' \
        _ "$kit/ovh-deploy-command.sh" $((8 * 1024 * 1024))
    if bash -c 'source "$1"; free=$2; df() { printf "h\nfs 1 1 %s 1%% /\n" "$free"; }; enough_space' \
        _ "$kit/ovh-deploy-command.sh" $((8 * 1024 * 1024 - 1)); then
        return 1
    fi
}

acl_restore() {
    local path="$TEST_STORE/site" group uid
    mkdir -m 0755 "$path"
    group=$("$REAL_ID" -g)
    uid=$("$REAL_ID" -u)
    setfacl -m 'g::rwx,m::r-x' "$path"
    getfacl -pn "$path" > "$TEST_STORE/acl.before"
    bash -c 'source "$1"; grant_group "$2" rwx 1 "$3" "$4"' _ "$kit/ovh-common.sh" "$path" "$group" "$uid"
    getfacl -pcne "$path" > "$TEST_STORE/acl.applied"
    grep -Fxq $'group::r-x\t#effective:r-x' "$TEST_STORE/acl.applied"
    grep -Fxq $'group:'"$group"$':rwx\t#effective:rwx' "$TEST_STORE/acl.applied"
    grep -Fxq 'other::r-x' "$TEST_STORE/acl.applied"
    setfacl --restore="$TEST_STORE/acl.before"
    getfacl -pn "$path" > "$TEST_STORE/acl.after"
    diff -u "$TEST_STORE/acl.before" "$TEST_STORE/acl.after"
}

case_run 'OVH dry-run prints both source-pin variants' dry_run
case_run 'usage and malformed arguments' arguments
case_run 'pin, alias and hostname validation' bad_pin
case_run 'key-only uses the same mode-600 key on retry' key_only
case_run 'mini setup, check, retry and rollback' mini_lifecycle
case_run 'invalid PAT type and account never reach gh login' bad_token
case_run 'gh fallback cleanup and hidden token under bash -x' login_fallback
case_run 'tap push permission failure' push_denied
case_run 'existing SSH identity conflict leaves config intact' conflicting_identity
case_run 'unmanaged GitHub Keychain credential is preserved' existing_keychain
case_run 'local rsync preserves shared ACLs and public site modes' shared_receiver
case_run 'ACL grants preserve effective access and the baseline restores exactly' acl_restore
case_run 'forced command admits only release, site and probe commands' forced_command
printf '%d sandbox tests passed.\n' "$passed"
