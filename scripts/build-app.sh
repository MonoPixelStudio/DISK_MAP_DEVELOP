#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"

swift build --configuration release --product DiskMap
task_bin_dir="$(swift build --configuration release --show-bin-path)"
task_bundle="$task_root/dist/DiskMap.app"

# Never follow a replaced build-output path into an unrelated directory.
for task_output in "$task_root/dist" "$task_bundle" "$task_bundle/Contents" \
    "$task_bundle/Contents/MacOS" "$task_bundle/Contents/Resources" \
    "$task_bundle/Contents/MacOS/DiskMap" "$task_bundle/Contents/Info.plist" \
    "$task_bundle/Contents/Resources/AppIcon.icns"; do
    if [ -L "$task_output" ]; then
        printf 'Refused symlink build output: %s\n' "$task_output" >&2
        exit 1
    fi
done
mkdir -p "$task_bundle/Contents/MacOS" "$task_bundle/Contents/Resources"
cp "$task_bin_dir/DiskMap" "$task_bundle/Contents/MacOS/DiskMap"
cp "$task_root/Support/Info.plist" "$task_bundle/Contents/Info.plist"
chmod +x "$task_bundle/Contents/MacOS/DiskMap"
swift -module-cache-path "$task_root/.build/icon-module-cache" "$task_root/scripts/generate-icon.swift" "$task_root/dist/DiskMap.iconset"
/usr/bin/iconutil --convert icns --output "$task_bundle/Contents/Resources/AppIcon.icns" "$task_root/dist/DiskMap.iconset"
/usr/bin/plutil -lint "$task_bundle/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$task_bundle"
/usr/bin/codesign --verify --deep --strict "$task_bundle"
printf 'Built app: %s\n' "$task_bundle"
