#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
task_base="$task_root/.diskmap-test-fixtures"
if [ -L "$task_base" ] || { [ -e "$task_base" ] && [ ! -d "$task_base" ]; }; then
    printf 'Refused unsafe fixture base\n' >&2; exit 1
fi
mkdir -p "$task_base"
[ "$(cd "$task_base" && pwd -P)" = "$task_base" ] || exit 1
task_fixture="$(mktemp -d "$task_base/ReleasePackage.XXXXXXXX")"
cleanup() {
    if [ "$(dirname "$task_fixture")" = "$task_base" ] && [ ! -L "$task_fixture" ] \
       && [ "$(cd "$task_fixture" && pwd -P)" = "$task_fixture" ]; then
        rm -rf -- "$task_fixture" # Only this invocation's newly created fixture.
    else
        printf 'Refused unsafe package-test cleanup\n' >&2
    fi
}
trap cleanup EXIT
task_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Support/Info.plist)"
task_archive="$task_root/dist/DiskMap-$task_version-$(uname -m).zip"
/usr/bin/shasum -a 256 --check "$task_archive.sha256"
/usr/bin/ditto -x -k "$task_archive" "$task_fixture"
task_app="$task_fixture/DiskMap.app"
/usr/bin/codesign --verify --deep --strict "$task_app"
[ -x "$task_app/Contents/MacOS/DiskMap" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$task_app/Contents/Info.plist")" = "$task_version" ]
/usr/bin/cmp "$task_app/Contents/MacOS/DiskMap" "$task_root/dist/DiskMap.app/Contents/MacOS/DiskMap"
/usr/bin/iconutil --convert iconset --output "$task_fixture/AppIcon.iconset" "$task_app/Contents/Resources/AppIcon.icns"
[ "$(/usr/bin/sips -g pixelWidth "$task_fixture/AppIcon.iconset/icon_16x16.png" | awk '/pixelWidth/ {print $2}')" = 16 ]
/usr/bin/file "$task_app/Contents/MacOS/DiskMap"
/usr/bin/otool -l "$task_app/Contents/MacOS/DiskMap" | rg -A 6 'cmd LC_BUILD_VERSION'
printf 'PASS archive checksum, relocation, signature, binary/version and icon\n'
