#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
build_args=(-c release)
if [[ "${1:-}" == "--universal" ]]; then build_args+=(--arch arm64 --arch x86_64); fi
Scripts/swift.sh build "${build_args[@]}"
binary_dir="$(Scripts/swift.sh build "${build_args[@]}" --show-bin-path)"
app_path="$PWD/dist/Otowake.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/Otowake" "$app_path/Contents/MacOS/Otowake"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
swift -module-cache-path "$PWD/.build/module-cache" Scripts/make-icon.swift "$PWD/.build/AppIcon.iconset"
cp .build/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
# Local use needs no paid developer account. A distribution identity may be supplied.
codesign --force --sign "${OTOWAKE_SIGNING_IDENTITY:--}" --timestamp=none "$app_path"
codesign --verify --strict "$app_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" dist/Otowake-macOS.zip
print "Built: $app_path"
