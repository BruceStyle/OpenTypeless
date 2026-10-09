#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/Resources/AppIcon.png"
OUTPUT="$ROOT_DIR/Resources/AppIcon.icns"
[[ -f "$SOURCE" ]] || { echo "Missing app icon source: $SOURCE" >&2; exit 1; }

ICON_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opentypeless-icon.XXXXXX")"
trap 'rm -rf "$ICON_WORK_DIR"' EXIT
ICONSET="$ICON_WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"

# Supply both standard and Retina representations; preserve the source alpha.
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  /usr/bin/sips -z "$retina_size" "$retina_size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil --convert icns "$ICONSET" --output "$ICON_WORK_DIR/AppIcon.icns"
cp "$ICON_WORK_DIR/AppIcon.icns" "$OUTPUT"
echo "Generated: $OUTPUT"
