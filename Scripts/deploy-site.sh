#!/bin/bash
# Publishes docs/ to plainsay.app.
#
#   ./Scripts/deploy-site.sh
#
# The marketing site had no deploy path at all until this existed: it was
# uploaded by hand once and then silently rotted — for days it advertised a
# "Live typing" feature that had already been removed from the app, and a
# macOS 15 requirement that had already been lowered to 14. Anything a
# release changes in docs/ has to actually reach the server, so this runs
# from release.sh too.
set -euo pipefail

cd "$(dirname "$0")/.."

# release.sh runs these same gates in its preflight, so a release that would
# be refused here fails before anything is built, signed or published —
# rather than after the update feed is already live, which would leave the
# site describing a version that no longer matches the app being shipped.
CHECK_ONLY=0
[ "${1:-}" = "--check-only" ] && CHECK_ONLY=1

# This publishes the *working tree*, not origin/main, with --delete. A stale
# or dirty checkout therefore silently reverts the live site and removes any
# page added since — which very nearly happened from a checkout 28 commits
# behind, wiping a parallel branch's work. Neither condition is detectable
# after the fact: rsync reports success either way.
verify_checkout_is_current() {
  # Not [ -d .git ]: inside a git worktree .git is a *file*, and that test
  # silently skipped the whole check there — which is exactly the shape of
  # checkout this guard exists to catch.
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  if [ "${DEPLOY_SITE_SKIP_GIT_CHECK:-}" = "1" ]; then
    echo "!! DEPLOY_SITE_SKIP_GIT_CHECK=1 — publishing this working tree unverified" >&2
    return 0
  fi

  local branch remote
  branch=$(git rev-parse --abbrev-ref HEAD)
  remote="origin/${DEPLOY_SITE_BRANCH:-main}"

  git fetch --quiet origin "${DEPLOY_SITE_BRANCH:-main}" || {
    echo "cannot reach origin to check whether this checkout is current." >&2
    echo "Deploying blind can revert the live site. Re-run with DEPLOY_SITE_SKIP_GIT_CHECK=1 only if you are certain." >&2
    exit 1
  }

  local behind
  behind=$(git rev-list --count "HEAD..$remote")
  if [ "$behind" -gt 0 ]; then
    echo "refusing to deploy: this checkout is $behind commit(s) behind $remote (on $branch)." >&2
    echo "Publishing it would revert the live site to an older version and delete anything added since." >&2
    echo "Run: git pull --ff-only origin ${DEPLOY_SITE_BRANCH:-main}" >&2
    exit 1
  fi

  # Anything uncommitted under docs/ goes live having passed through no review
  # and exists nowhere in history to roll back to.
  if [ -n "$(git status --porcelain -- docs/)" ]; then
    echo "refusing to deploy: docs/ has uncommitted changes:" >&2
    git status --short -- docs/ >&2
    echo "Commit them (so the live site is reproducible from a tag) or stash them." >&2
    exit 1
  fi
}

verify_checkout_is_current

validate_legal_page() {
  local page="$1"
  [ -s "$page" ] || {
    echo "$page missing or empty — do not deploy Cloud marketing without the reviewed document" >&2
    exit 1
  }
  grep -Fq "DMT Sp. z o.o." "$page" || {
    echo "$page does not identify DMT Sp. z o.o. as the operator" >&2
    exit 1
  }
  if grep -Fq "LEGAL_REVIEW_REQUIRED" "$page"; then
    echo "$page still contains LEGAL_REVIEW_REQUIRED — complete legal review before deploying" >&2
    exit 1
  fi
}

validate_legal_page docs/privacy/index.html
validate_legal_page docs/terms/index.html

if [ "$CHECK_ONLY" = "1" ]; then
  echo "==> docs/ is publishable from this checkout"
  exit 0
fi

HOST="${HOST:-codex-server}"
REMOTE_DIR=/var/www/plainsay-app

[ -f docs/index.html ] || { echo "docs/index.html missing — wrong directory?" >&2; exit 1; }

echo "==> Publishing docs/ to $HOST:$REMOTE_DIR"
ssh "$HOST" "sudo mkdir -p $REMOTE_DIR && sudo chown -R \$(whoami) $REMOTE_DIR"
# --delete so a page removed from docs/ actually disappears from the site
# rather than lingering as an orphan nobody links to but crawlers still index.
# Internal planning material, if present, is not website content.
rsync -az --delete --delete-excluded \
  --exclude '/launch/' \
  --exclude '/superpowers/' \
  docs/ "$HOST:$REMOTE_DIR/"
ssh "$HOST" "sudo chown -R www-data:www-data $REMOTE_DIR && sudo chmod -R a+rX $REMOTE_DIR"

echo "==> Live: https://plainsay.app/"
