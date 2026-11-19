#!/bin/zsh
set -eu
project=${0:A:h:h}
cd "$project"
mkdir -p .build dist
export CLANG_MODULE_CACHE_PATH="$project/.build/module-cache"
swift build --build-system native --disable-sandbox --cache-path "$project/.build/cache" -c release --arch arm64 --product DiskInventory
binary_dir=$(swift build --build-system native --disable-sandbox --cache-path "$project/.build/cache" -c release --arch arm64 --show-bin-path)
stage=$(mktemp -d "$project/.build/package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/Disk Inventory.app"
mkdir -p "$app/Contents/"{MacOS,Resources}
swift Scripts/Icon.swift "$app/Contents/Resources/Inventory.icns"
sips -g format "$app/Contents/Resources/Inventory.icns"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp "$binary_dir/DiskInventory" "$app/Contents/MacOS/DiskInventory"
identity=$(security find-identity -v -p codesigning | awk '/\)/ {print $2; exit}')
codesign --force --sign "${identity:--}" "$app"
codesign --verify --strict "$app"
plutil -lint "$app/Contents/Info.plist"
test "$(lipo -archs "$app/Contents/MacOS/DiskInventory")" = arm64
destination="${1:-$project/dist/Disk Inventory.app}"
if [[ -d "$destination" ]]; then mv "$destination" "$stage/previous.app"; fi
if ! mv "$app" "$destination"; then
    if [[ -d "$stage/previous.app" ]]; then mv "$stage/previous.app" "$destination"; fi
    exit 1
fi
echo "$destination"
