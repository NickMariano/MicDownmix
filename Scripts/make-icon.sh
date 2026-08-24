#!/bin/bash
#
# Turns a single square PNG into the .icns the app bundle needs.
#
# macOS expects every size from 16pt to 512pt at 1x and 2x. Supplying one large square and letting
# sips downscale is enough: iconutil rejects an iconset with any size missing, so all ten are made.

set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="${1:-Resources/icon-source.png}"
ICONSET="build/MicDownmix.iconset"
OUTPUT="Resources/MicDownmix.icns"

[ -f "$SOURCE" ] || { echo "error: $SOURCE not found. Pass the path to a square PNG." >&2; exit 1; }

# Source images arrive carrying metadata: screenshots keep EXIF and XMP, generated images can embed
# a C2PA provenance manifest naming the tool that made them. Strip it before anything is committed.
python3 Scripts/strip-png-metadata.py "$SOURCE"

WIDTH="$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth/{print $2}')"
HEIGHT="$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/{print $2}')"
if [ "$WIDTH" != "$HEIGHT" ]; then
    echo "error: icon must be square, got ${WIDTH}x${HEIGHT}" >&2
    exit 1
fi
if [ "$WIDTH" -lt 512 ]; then
    echo "warning: source is only ${WIDTH}px; 1024 gives a sharp icon on Retina displays" >&2
fi

# Source artwork usually paints its rounded shape onto an opaque background, which macOS renders as
# a square. Mask it to a real rounded shape with transparent corners and Apple's proportions.
PADDED="build/icon-shaped.png"
mkdir -p build
swift "Scripts/shape-icon.swift" "$SOURCE" "$PADDED"
SOURCE="$PADDED"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -z $((SIZE * 2)) $((SIZE * 2)) "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done

iconutil --convert icns "$ICONSET" --output "$OUTPUT"
rm -rf "$ICONSET" "$PADDED"
echo "built $OUTPUT ($(du -h "$OUTPUT" | cut -f1 | tr -d ' '))"
