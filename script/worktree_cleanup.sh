#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=worktree_runtime.sh
source "$ROOT_DIR/script/worktree_runtime.sh"

if [[ "$SAKURACORD_IS_MAIN_WORKTREE" -eq 1 ]]; then
  echo "Main checkout detected: linked-worktree cleanup is not applicable; no process was stopped."
  exit 0
fi

sakuracord_stop_scoped_app

if [[ -f "$SAKURACORD_OPERATION_LOCK/pid" ]]; then
  owner="$(cat "$SAKURACORD_OPERATION_LOCK/pid" 2>/dev/null || true)"
  if ! [[ "$owner" =~ ^[0-9]+$ ]] || ! kill -0 "$owner" 2>/dev/null; then
    rm -f "$SAKURACORD_OPERATION_LOCK/pid"
    rmdir "$SAKURACORD_OPERATION_LOCK" 2>/dev/null || true
  fi
fi

echo "Stopped linked-worktree SakuraCord variant $SAKURACORD_VARIANT_ID."
