#!/bin/bash
# Regenerate MorphyPets/Resources/AppIcon.icns from a source image (PNG or JPEG, ideally
# square, ≥512px). Skips the 1024 size since standalone .app distribution doesn't need
# it (only required for App Store submission) — saves ~1MB.
#
# Usage:
#   ./scripts/make_icon.sh path/to/source.png

set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-}"
if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
    echo "Usage: $0 <source-image>" >&2
    exit 1
fi

TMP=$(mktemp -d)
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$TMP"' EXIT

for s in 16 32 64 128 256 512; do
    sips -s format png -z $s $s "$SRC" --out "$ICONSET/tmp_$s.png" >/dev/null
done

cp "$ICONSET/tmp_16.png"  "$ICONSET/icon_16x16.png"
cp "$ICONSET/tmp_32.png"  "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/tmp_32.png"  "$ICONSET/icon_32x32.png"
cp "$ICONSET/tmp_64.png"  "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/tmp_128.png" "$ICONSET/icon_128x128.png"
cp "$ICONSET/tmp_256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/tmp_256.png" "$ICONSET/icon_256x256.png"
cp "$ICONSET/tmp_512.png" "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/tmp_512.png" "$ICONSET/icon_512x512.png"
rm "$ICONSET"/tmp_*.png

mkdir -p MorphyPets/Resources
iconutil -c icns "$ICONSET" -o MorphyPets/Resources/AppIcon.icns
echo "Wrote MorphyPets/Resources/AppIcon.icns ($(ls -lh MorphyPets/Resources/AppIcon.icns | awk '{print $5}'))"
