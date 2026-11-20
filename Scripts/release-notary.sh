#!/bin/bash

release_notarytool() {
	local keychain="${PLAINSAY_RELEASE_KEYCHAIN:-$HOME/Library/Keychains/herdr-release.keychain-db}"
	local password_file="${PLAINSAY_RELEASE_KCPASS:-$HOME/.herdr-release/kcpass}"
	if [ -z "${PLAINSAY_RELEASE_KEYCHAIN+x}" ] && [ ! -e "$password_file" ] && [ ! -L "$password_file" ]; then
		xcrun notarytool "$@" --keychain-profile plainsay-notary
		return
	fi

	if [ ! -f "$password_file" ] || ! (
		# Keep the password out of shell traces, argv, and the environment.
		set +ax
		set -o pipefail
		local +x password command_line
		local mode keychain_arg LC_ALL=C
		# stat inspects the same open file that supplies the password below.
		mode=$(stat -f '%OLp') || exit 1
		if (( 8#$mode & 044 )); then
			printf 'Release keychain password file is group/world readable: %s\n' "$password_file" >&2
			exit 1
		fi
		password=$(< /dev/stdin) && [ -n "$password" ] || exit 1
		[[ "$password$keychain" != *$'\n'* ]] || exit 1

		# security -i accepts double-quoted arguments with backslash escapes.
		password=${password//\\/\\\\}
		password=${password//\"/\\\"}
		keychain_arg=${keychain//\\/\\\\}
		keychain_arg=${keychain_arg//\"/\\\"}
		printf -v command_line 'unlock-keychain -p "%s" -- "%s"' "$password" "$keychain_arg"
		# Leave room for the newline in security's 4096-byte input buffer.
		(( ${#command_line} < 4095 )) || exit 1
		builtin printf '%s\n' "$command_line" | security -i >/dev/null
	) < "$password_file"; then
		printf 'Could not unlock release keychain %s using %s.\n' "$keychain" "$password_file" >&2
		return 1
	fi
	xcrun notarytool "$@" --keychain-profile plainsay-notary --keychain "$keychain"
}
