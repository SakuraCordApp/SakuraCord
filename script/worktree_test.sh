#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=worktree_runtime.sh
source "$ROOT_DIR/script/worktree_runtime.sh"

TARGET="${1:-app}"
sakuracord_acquire_operation_lock
trap sakuracord_release_operation_lock EXIT

run_tests() {
  swift test \
    --package-path "$1" \
    --cache-path "$SAKURACORD_SWIFTPM_CACHE_DIR" \
    --scratch-path "$1/.build"
}

case "$TARGET" in
  app)
    run_tests "$ROOT_DIR/App"
    ;;
  protocol)
    run_tests "$ROOT_DIR/Packages/DiscordProtocol"
    ;;
  all)
    run_tests "$ROOT_DIR/Packages/SakuraCordModels"
    run_tests "$ROOT_DIR/Packages/DiscordProtocol"
    run_tests "$ROOT_DIR/Packages/SakuraCordPersistence"
    run_tests "$ROOT_DIR/Packages/MessageRendering"
    run_tests "$ROOT_DIR/Packages/MediaPipeline"
    run_tests "$ROOT_DIR/Packages/SakuraCordPluginSDK"
    run_tests "$ROOT_DIR/App"
    ;;
  *)
    echo "usage: $0 [app|protocol|all]" >&2
    exit 2
    ;;
esac
