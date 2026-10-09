#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
"$task_root/scripts/build-app.sh"
task_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Support/Info.plist)"
task_arch="$(uname -m)"
task_archive="$task_root/dist/DiskMap-$task_version-$task_arch.zip"
for task_output in "$task_archive" "$task_archive.sha256" "$task_root/dist/QUICK_START.md"; do
    if [ -L "$task_output" ] || { [ -e "$task_output" ] && [ ! -f "$task_output" ]; }; then
        printf 'Refused unsafe release output: %s\n' "$task_output" >&2
        exit 1
    fi
done
/usr/bin/ditto --rsrc --extattr --acl -c -k --keepParent "$task_root/dist/DiskMap.app" "$task_archive"
/usr/bin/shasum -a 256 "${task_archive#"$task_root/"}" > "$task_archive.sha256"
cp "$task_root/docs/QUICK_START.md" "$task_root/dist/QUICK_START.md"
printf 'Packaged app: %s\n' "$task_archive"
