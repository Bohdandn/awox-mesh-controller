#!/bin/zsh
set -euo pipefail

root_dir=${0:A:h}
app_name="AwoX Mesh Controller"
app_dir="$root_dir/build/$app_name.app"
dist_dir="$root_dir/dist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root_dir/Info.plist")
archive="$dist_dir/AwoX-Mesh-Controller-$version-macos.zip"

"$root_dir/build.sh" >/dev/null
codesign --verify --deep --strict "$app_dir"

rm -rf "$dist_dir"
mkdir -p "$dist_dir"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive"

echo "$archive"