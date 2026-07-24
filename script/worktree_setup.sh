#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=worktree_runtime.sh
source "$ROOT_DIR/script/worktree_runtime.sh"

sakuracord_acquire_operation_lock
trap sakuracord_release_operation_lock EXIT

sakuracord_print_identity
if [[ "$SAKURACORD_IS_MAIN_WORKTREE" -eq 1 ]]; then
  echo "Main checkout detected: resolving dependencies only; no linked-worktree variant will be created."
else
  echo "Linked worktree detected: resolving dependencies into this checkout's isolated paths."
fi

mkdir -p "$SAKURACORD_DIST_DIR"
swift package \
  --package-path "$SAKURACORD_PACKAGE_DIR" \
  --cache-path "$SAKURACORD_SWIFTPM_CACHE_DIR" \
  --scratch-path "$SAKURACORD_SCRATCH_DIR" \
  resolve
