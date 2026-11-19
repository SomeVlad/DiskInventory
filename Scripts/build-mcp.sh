#!/bin/zsh
set -eu
project=${0:A:h:h}
cd "$project"
mkdir -p .build dist
export CLANG_MODULE_CACHE_PATH="$project/.build/module-cache"
swift build --build-system native --disable-sandbox --cache-path "$project/.build/cache" -c release --arch arm64 --product inventorymcp
binary_dir=$(swift build --build-system native --disable-sandbox --cache-path "$project/.build/cache" -c release --arch arm64 --show-bin-path)
cp "$binary_dir/inventorymcp" dist/inventorymcp
identity=$(security find-identity -v -p codesigning | awk '/\)/ {print $2; exit}')
codesign --force --sign "${identity:--}" dist/inventorymcp
echo "$project/dist/inventorymcp"
