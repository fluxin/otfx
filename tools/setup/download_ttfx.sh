#!/usr/bin/env sh
set -eu

REPOSITORY='https://github.com/omacom-io/ttfx'
REVISION='14ed2742596f0056b13e25d14a83ea851adc2294'
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DESTINATION="$ROOT/third_party/ttfx"
PATCH="$ROOT/tools/patches/ttfx-build.patch"

if ! command -v git >/dev/null 2>&1; then
	echo 'git is required to download the ttfx reference.' >&2
	exit 1
fi

if test -e "$DESTINATION"; then
	if test -d "$DESTINATION/.git" && test "$(git -C "$DESTINATION" rev-parse HEAD 2>/dev/null || true)" = "$REVISION"; then
		if git -C "$DESTINATION" diff --quiet; then
			echo "ttfx is already present at $REVISION (v0.5.1)"
			exit 0
		fi
		if test -f "$PATCH" && git -C "$DESTINATION" apply --reverse --check "$PATCH"; then
			echo "ttfx is already present at $REVISION (v0.5.1) with compile-timing probe patch"
			exit 0
		fi
	fi
	echo "refusing to replace existing $DESTINATION" >&2
	exit 1
fi

mkdir -p "$ROOT/third_party"
git clone --no-checkout "$REPOSITORY" "$DESTINATION"
git -C "$DESTINATION" checkout --detach "$REVISION"

echo "Downloaded ttfx at $REVISION (v0.5.1)"
echo "Build it with: $DESTINATION/bin/build"
