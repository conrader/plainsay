#!/bin/bash
# Run on OVH via sudo. The OVH step uses mini-m4, and --macbook uses macbook-m4.
set -euo pipefail
export DRY_RUN="${DRY_RUN:-1}"
cd "$(dirname "$0")"
if [[ ${1:-} == --macbook ]]; then
    exec python3 -B oneoff-prune-old-copies.py "$@" <<'PATHS'
/Users/konradsierzputowski/Downloads/Plainsay-latest.dmg
PATHS
fi
exec python3 -B oneoff-prune-old-copies.py "$@" <<'PATHS'
/var/www/plainsay-updates/releases/Plainsay-0.1.1.zip
/var/www/plainsay-updates/releases/Plainsay-0.1.2.zip
/var/www/plainsay-updates/releases/Plainsay-0.1.3.zip
/var/www/plainsay-updates/releases/Plainsay-0.1.4.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.0.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.1.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.2.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.3.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.4.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.5.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.6.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.7.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.8.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.9.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.10.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.11.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.12.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.13.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.14.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.15.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.16.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.17.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.18.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.19.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.20.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.21.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.23.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.24.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.25.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.26.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.27.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.28.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.29.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.30.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.31.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.32.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.33.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.34.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.35.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.36.zip
/var/www/plainsay-updates/releases/Plainsay-0.2.37.zip
/var/backups/plainsay-launch-0.2.24
PATHS
