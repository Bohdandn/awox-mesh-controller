#!/bin/zsh
set -euo pipefail

root_dir=${0:A:h}
build_dir="$root_dir/build"
app_dir="$build_dir/AwoX Mesh Controller.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/awox-mesh-controller.XXXXXX")
iconset_dir="$temporary_dir/AppIcon.iconset"
metadata_plist="$temporary_dir/Info.plist"
trap 'rm -rf "$temporary_dir"' EXIT

rm -rf "$build_dir"
mkdir -p "$macos_dir" "$resources_dir" "$iconset_dir"
cp "$root_dir/Info.plist" "$metadata_plist"
commit_hash=$(git -C "$root_dir" rev-parse HEAD | cut -c1-8)
build_date=$(date -u '+%Y-%m-%d %H:%M UTC')
/usr/libexec/PlistBuddy -c "Add :BuildCommitHash string $commit_hash" "$metadata_plist"
/usr/libexec/PlistBuddy -c "Add :BuildDate string '$build_date'" "$metadata_plist"

sips -s format png "$root_dir/Assets/AppIcon.svg" --out "$temporary_dir/AppIcon-1024.png" >/dev/null
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$temporary_dir/AppIcon-1024.png" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$temporary_dir/AppIcon-1024.png" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$resources_dir/AppIcon.icns"

xcrun clang \
    -O2 \
    -c "$root_dir/Sources/AwoXMeshController/CryptoBridge.c" \
    -o "$temporary_dir/CryptoBridge.o"

xcrun swiftc \
    -swift-version 5 \
    -O \
    -framework AppKit \
    -framework CoreBluetooth \
    -framework Network \
    -framework Security \
    "$root_dir/Sources/AwoXMeshController/"*.swift \
    "$temporary_dir/CryptoBridge.o" \
    -o "$macos_dir/AwoXMeshController"

cp "$metadata_plist" "$contents_dir/Info.plist"
codesign --force --sign - --identifier com.github.bohdandn.awox-mesh-controller "$app_dir"

echo "$app_dir"