#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=worktree_runtime.sh
source "$ROOT_DIR/script/worktree_runtime.sh"

TARGET="${1:-app}"
sakuracord_acquire_operation_lock
trap sakuracord_release_operation_lock EXIT

sakuracord_print_identity

run_tests() {
  local package_path="$1"
  local bin_dir
  local framework

  swift build \
    --package-path "$package_path" \
    --cache-path "$SAKURACORD_SWIFTPM_CACHE_DIR" \
    --scratch-path "$package_path/.build" \
    --build-tests
  bin_dir="$(swift build \
    --package-path "$package_path" \
    --cache-path "$SAKURACORD_SWIFTPM_CACHE_DIR" \
    --scratch-path "$package_path/.build" \
    --show-bin-path)"

  # SwiftPM does not stage binary-target frameworks where its macOS test
  # helper searches for them. Keep the test host self-contained without
  # changing the application bundle or a global dynamic-library path.
  for framework in "$bin_dir"/*.framework; do
    [[ -d "$framework" ]] || continue
    mkdir -p "$bin_dir/PackageFrameworks"
    ditto "$framework" "$bin_dir/PackageFrameworks/$(basename "$framework")"
  done

  swift test \
    --package-path "$package_path" \
    --cache-path "$SAKURACORD_SWIFTPM_CACHE_DIR" \
    --scratch-path "$package_path/.build" \
    --skip-build
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
