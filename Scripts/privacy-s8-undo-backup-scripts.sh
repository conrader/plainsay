#!/bin/bash
# Use the same preflight and pinned checksums as the forward park.
set -euo pipefail
if [[ $# != 0 ]]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 2
fi
# sb-park snapshots and rebinds this literal source path.
# shellcheck disable=SC1091
source /home/ubuntu/work/Plainsay/parks/privacy-s8-install-backup-scripts.sh --undo
