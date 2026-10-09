#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
swift build --configuration release --product DiskMapChecks
task_bin_dir="$(swift build --configuration release --show-bin-path)"
"$task_bin_dir/DiskMapChecks" --benchmark
