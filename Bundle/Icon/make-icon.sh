#!/bin/sh
# Redraws the icon and rebuilds Bundle/AppIcon.icns from it. Run after changing draw-icon.swift.
set -e
cd "$(dirname "$0")"
swift draw-icon.swift icon.png
set_dir="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$set_dir"
for s in 16 32 128 256 512; do
    sips -z $s $s icon.png --out "$set_dir/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) icon.png --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o ../AppIcon.icns
echo "Made Bundle/AppIcon.icns"
