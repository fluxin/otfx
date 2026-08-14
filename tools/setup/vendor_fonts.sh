#!/usr/bin/env sh
set -eu

# Vendors the TTFs the documentation renderer rasterizes with. Everything lands
# in the gitignored third_party tree, pinned by archive checksum, so the GIFs in
# docs/images are reproducible without committing font binaries.
#
# The chain is ordered: JetBrains Mono carries the terminal identity, DejaVu
# closes Latin Extended-B, and the Noto subset carries matrix's katakana.
# Together they cover every rune the effects emit, so no glyph renders as tofu.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DESTINATION="$ROOT/third_party/fonts"
LICENSES="$DESTINATION/licenses"

JETBRAINS_URL='https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip'
JETBRAINS_SHA='6f6376c6ed2960ea8a963cd7387ec9d76e3f629125bc33d1fdcd7eb7012f7bbf'
JETBRAINS_MEMBER='fonts/ttf/JetBrainsMono-Regular.ttf'
JETBRAINS_LICENSE='OFL.txt'

DEJAVU_URL='https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-fonts-ttf-2.37.zip'
DEJAVU_SHA='7576310b219e04159d35ff61dd4a4ec4cdba4f35c00e002a136f00e96a908b0a'
DEJAVU_MEMBER='dejavu-fonts-ttf-2.37/ttf/DejaVuSansMono.ttf'
DEJAVU_LICENSE='dejavu-fonts-ttf-2.37/LICENSE'
# decrypt scrambles across U+00AE-U+01C3; JetBrains Mono stops short of the
# Latin Extended-B tail, so this subset only has to carry that range.
DEJAVU_RANGE='U+00AE-01C3'

NOTO_URL='https://github.com/notofonts/noto-cjk/releases/download/Sans2.004/11_NotoSansMonoCJKjp.zip'
NOTO_SHA='6c8faf475ce78fa37486dd5d8920e4bb4450b1b0f3c497edf3ba2d25cf52ab78'
NOTO_MEMBER='NotoSansMonoCJKjp-Regular.otf'
NOTO_LICENSE='LICENSE'
# The whole halfwidth katakana block, not just the 34 runes matrix samples
# today, so re-rolling that pool does not require re-vendoring.
NOTO_RANGE='U+FF61-FF9F'

for tool in curl unzip sha256sum pyftsubset; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "$tool is required to vendor the documentation fonts." >&2
		case "$tool" in
		pyftsubset) echo 'Install it with: pip install fonttools' >&2 ;;
		esac
		exit 1
	fi
done

if test -f "$DESTINATION/JetBrainsMono-Regular.ttf" &&
	test -f "$DESTINATION/DejaVuSansMono-latinext.ttf" &&
	test -f "$DESTINATION/NotoSansMonoCJKjp-katakana.otf"; then
	echo "documentation fonts are already present in $DESTINATION"
	exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# Verifies before unpacking: a mismatched archive must never reach the subsetter.
fetch() {
	url=$1
	expected=$2
	archive=$3
	curl -fsSL --retry 3 -o "$WORK/$archive" "$url"
	actual=$(sha256sum "$WORK/$archive" | cut -d' ' -f1)
	if test "$actual" != "$expected"; then
		echo "checksum mismatch for $url" >&2
		echo "  expected $expected" >&2
		echo "  actual   $actual" >&2
		exit 1
	fi
	unzip -o -q "$WORK/$archive" -d "$WORK/${archive%.zip}"
}

mkdir -p "$DESTINATION" "$LICENSES"

fetch "$JETBRAINS_URL" "$JETBRAINS_SHA" jetbrains.zip
cp "$WORK/jetbrains/$JETBRAINS_MEMBER" "$DESTINATION/JetBrainsMono-Regular.ttf"
cp "$WORK/jetbrains/$JETBRAINS_LICENSE" "$LICENSES/JetBrainsMono-OFL.txt"

fetch "$DEJAVU_URL" "$DEJAVU_SHA" dejavu.zip
pyftsubset "$WORK/dejavu/$DEJAVU_MEMBER" \
	--unicodes="$DEJAVU_RANGE" \
	--no-hinting \
	--output-file="$DESTINATION/DejaVuSansMono-latinext.ttf"
cp "$WORK/dejavu/$DEJAVU_LICENSE" "$LICENSES/DejaVuSansMono-LICENSE.txt"

fetch "$NOTO_URL" "$NOTO_SHA" noto.zip
pyftsubset "$WORK/noto/$NOTO_MEMBER" \
	--unicodes="$NOTO_RANGE" \
	--no-hinting \
	--desubroutinize \
	--output-file="$DESTINATION/NotoSansMonoCJKjp-katakana.otf"
cp "$WORK/noto/$NOTO_LICENSE" "$LICENSES/NotoSansMonoCJKjp-LICENSE.txt"

echo "Vendored documentation fonts into $DESTINATION"
ls -1 "$DESTINATION" | sed 's/^/  /'
echo "Render the previews with: odin build tools/docs -out:tools/docs/render_previews && ./tools/docs/render_previews"
