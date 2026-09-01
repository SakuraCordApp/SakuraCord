#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=runtime.sh
source "$ROOT_DIR/script/runtime.sh"

sakuracord_acquire_operation_lock
trap sakuracord_release_operation_lock EXIT

mkdir -p "$SAKURACORD_DIST_DIR"
swift package \
  --package-path "$SAKURACORD_PACKAGE_DIR" \
  --cache-path "$SAKURACORD_SWIFTPM_CACHE_DIR" \
  --scratch-path "$SAKURACORD_SCRATCH_DIR" \
  resolve
