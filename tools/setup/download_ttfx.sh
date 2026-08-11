#!/usr/bin/env sh
set -eu

REPOSITORY='https://github.com/omacom-io/ttfx'
REVISION='adcdae9f17b84b795ca050ab6f6dc68cca1cc699'
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DESTINATION="$ROOT/third_party/ttfx"
PATCH="$ROOT/tools/patches/ttfx-build.patch"

if ! command -v git >/dev/null 2>&1; then
	echo 'git is required to download the ttfx reference.' >&2
	exit 1
fi

if test ! -f "$PATCH"; then
	echo "missing required reference patch: $PATCH" >&2
	exit 1
fi

if test -e "$DESTINATION"; then
	if test -d "$DESTINATION/.git" && test "$(git -C "$DESTINATION" rev-parse HEAD 2>/dev/null || true)" = "$REVISION"; then
		if git -C "$DESTINATION" apply --reverse --check "$PATCH"; then
			echo "ttfx is already present at $REVISION with the tracked patch"
			exit 0
		fi
		if git -C "$DESTINATION" diff --quiet && git -C "$DESTINATION" apply --check "$PATCH"; then
			git -C "$DESTINATION" apply "$PATCH"
			echo "Applied the tracked ttfx patch at $REVISION"
			exit 0
		fi
	fi
	echo "refusing to replace existing $DESTINATION" >&2
	exit 1
fi

mkdir -p "$ROOT/third_party"
git clone --no-checkout "$REPOSITORY" "$DESTINATION"
git -C "$DESTINATION" checkout --detach "$REVISION"
git -C "$DESTINATION" apply "$PATCH"

echo "Downloaded ttfx at $REVISION with the tracked patch"
echo "Build it with: $DESTINATION/bin/build"
