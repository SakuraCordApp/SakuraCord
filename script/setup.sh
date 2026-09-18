#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=runtime.sh
source "$ROOT_DIR/script/runtime.sh"

marrowchat_acquire_operation_lock
trap marrowchat_release_operation_lock EXIT

mkdir -p "$MARROWCHAT_DIST_DIR"
swift package \
  --package-path "$MARROWCHAT_PACKAGE_DIR" \
  --cache-path "$MARROWCHAT_SWIFTPM_CACHE_DIR" \
  --scratch-path "$MARROWCHAT_SCRATCH_DIR" \
  resolve
