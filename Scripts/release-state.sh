#!/bin/bash
# Local state shared by both macOS release entry points.

release_state_init() {
	STATE="${PLAINSAY_NIGHTLY_STATE_DIR:-$HOME/Library/Application Support/PlainsayRelease}"
	if [[ "$STATE" != /* ]]; then
		echo "Use an absolute release state path" >&2
		return 2
	fi
	(umask 077; mkdir -p "$STATE")
	STATE=$(cd "$STATE" && pwd -P)
	LOCK="$STATE/nightly.lock"
	PENDING="$STATE/publish.pending"
	LOCK_OWNED=0
}

acquire_release_lock() {
	if ! (umask 077; mkdir "$LOCK") 2>/dev/null; then
		echo "cannot acquire $LOCK. Inspect the lock before running again." >&2
		return 1
	fi
	LOCK_OWNED=1
	printf '%s\n' "$$" > "$LOCK/pid"
}

release_lock() {
	if [ "$LOCK_OWNED" = 1 ]; then
		rm -f "$LOCK/pid" "$LOCK/last.plist" "$LOCK/main.plist" "$LOCK/publish.pending"
		rmdir "$LOCK"
	fi
}

check_pending_release() {
	if [ -e "$PENDING" ]; then
		echo "publication needs reconciliation. See $PENDING and RELEASING.md." >&2
		return 1
	fi
}

check_nightly_main() {
	local source="$1" remote_main
	remote_main=$(git ls-remote --exit-code origin refs/heads/main | cut -f 1) || return 1
	if [ "$remote_main" != "$source" ]; then
		echo "origin/main moved during preparation; deferring publication" >&2
		return 1
	fi
}
