#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

source_svg="$PWD/Assets/PomoIcon.svg"
output_png="$PWD/Assets/PomoIcon.png"
output_icns="$PWD/Assets/PomoIcon.icns"
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

qlmanage -t -s 1024 -o "$temp_dir" "$source_svg" >/dev/null
rendered="$temp_dir/PomoIcon.svg.png"
iconset="$temp_dir/PomoIcon.iconset"
mkdir "$iconset"

cp "$rendered" "$temp_dir/PomoIcon.png"
sips -z 16 16 "$rendered" --out "$iconset/icon_16x16.png" >/dev/null
sips -z 32 32 "$rendered" --out "$iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$rendered" --out "$iconset/icon_32x32.png" >/dev/null
sips -z 64 64 "$rendered" --out "$iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$rendered" --out "$iconset/icon_128x128.png" >/dev/null
sips -z 256 256 "$rendered" --out "$iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$rendered" --out "$iconset/icon_256x256.png" >/dev/null
sips -z 512 512 "$rendered" --out "$iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$rendered" --out "$iconset/icon_512x512.png" >/dev/null
cp "$rendered" "$iconset/icon_512x512@2x.png"
iconutil --convert icns --output "$temp_dir/PomoIcon.icns" "$iconset"

mv "$temp_dir/PomoIcon.png" "$output_png"
mv "$temp_dir/PomoIcon.icns" "$output_icns"
