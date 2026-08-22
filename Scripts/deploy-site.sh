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
