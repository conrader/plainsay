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
	if [ -e "$PENDING" ] || [ -L "$PENDING" ]; then
		echo "publication needs reconciliation. See $PENDING and RELEASING.md." >&2
		return 1
	fi
}

prune_older_release_stages() {
	local stage stage_name scratch scratch_name marker old
	# All release entry points take LOCK before using these directories.
	check_pending_release || return 1
	for stage in "$STATE"/release.* "$STATE"/nightly.*/source/build/.release-stage; do
		[[ -d "$stage" && -O "$stage" && ! -L "$stage" && "$stage" != "$RELEASE_STAGE" ]] || continue
		stage_name=${stage##*/}
		if [ "$stage_name" = ".release-stage" ]; then
			scratch=${stage%/source/build/.release-stage}
			scratch_name=${scratch##*/}
			[[ "$scratch_name" =~ ^nightly\.[A-Za-z0-9]{6}$ && ! -L "$scratch" &&
				! -L "$scratch/source" && ! -L "$scratch/source/build" ]] || continue
		else
			[[ "$stage_name" =~ ^release\.[0-9a-f]{64}$ ]] || continue
		fi
		[[ ! -e "$stage/publish.pending" && ! -L "$stage/publish.pending" ]] || continue
		marker="$stage/.release-version"
		if [[ -f "$marker" && ! -L "$marker" ]]; then
			IFS= read -r old < "$marker" || continue
		else
			# Identify older-format stages from their stamp or built app.
			marker="$stage/build/Plainsay.app.release-stamp"
			[[ ! -L "$stage/build" ]] || continue
			if [[ -f "$marker" && ! -L "$marker" ]]; then
				read -r old _ < "$marker" || continue
			else
				marker="$stage/build/Plainsay.app/Contents/Info.plist"
				[[ ! -L "$stage/build/Plainsay.app" && ! -L "$stage/build/Plainsay.app/Contents" &&
					-f "$marker" && ! -L "$marker" ]] || continue
				old=$(PlistBuddy -c 'Print :CFBundleShortVersionString' "$marker" 2>/dev/null) || continue
			fi
		fi
		[[ "$old" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
		# Compare decimal components without machine-integer overflow.
		if awk -v old="$old" -v current="$VERSION" 'BEGIN {
			split(old, a, "."); split(current, b, ".")
			for (i = 1; i <= 3; i++) {
				sub(/^0+/, "", a[i]); sub(/^0+/, "", b[i])
				if (length(a[i]) != length(b[i])) exit !(length(a[i]) < length(b[i]))
				if (("v" a[i]) != ("v" b[i])) exit !(("v" a[i]) < ("v" b[i]))
			}
			exit 1
		}'; then
			rm -rf -- "$stage" || return 1
		fi
	done
}

check_nightly_main() {
	local source="$1" remote_main
	remote_main=$(git ls-remote --exit-code origin refs/heads/main | cut -f 1) || return 1
	if [ "$remote_main" != "$source" ]; then
		echo "origin/main moved during preparation; deferring publication" >&2
		return 1
	fi
}
