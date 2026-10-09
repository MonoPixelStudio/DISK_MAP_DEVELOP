#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
"$task_root/scripts/build-app.sh"
/usr/bin/open "$task_root/dist/DiskMap.app"
