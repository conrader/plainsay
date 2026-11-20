#!/bin/bash
# Use the same preflight and pinned checksums as the forward park.
set -euo pipefail
if [[ $# != 0 ]]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 2
fi
exec "$(dirname -- "${BASH_SOURCE[0]}")/privacy-s8-install-backup-scripts.sh" --undo
