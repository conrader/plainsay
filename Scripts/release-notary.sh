#!/bin/bash

release_notarytool() {
	local keychain="${PLAINSAY_RELEASE_KEYCHAIN:-$HOME/Library/Keychains/herdr-release.keychain-db}"
	local password_file="$HOME/.herdr-release/kcpass"
	# Keep the password out of shell traces, including when the caller uses bash -x.
	if ! (
		set +x
		kcpass=$(<"$password_file") && [ -n "$kcpass" ] &&
			security unlock-keychain -p "$kcpass" "$keychain"
	) >/dev/null 2>&1; then
		printf 'Could not unlock release keychain %s using %s.\n' "$keychain" "$password_file" >&2
		return 1
	fi
	xcrun notarytool "$@" --keychain-profile plainsay-notary --keychain "$keychain"
}
