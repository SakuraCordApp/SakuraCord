#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=runtime.sh
source "$ROOT_DIR/script/runtime.sh"

TARGET="${1:-app}"
marrowchat_acquire_operation_lock
trap marrowchat_release_operation_lock EXIT

run_tests() {
  local package_path="$1"
  local bin_dir
  local framework

  swift build \
    --package-path "$package_path" \
    --cache-path "$MARROWCHAT_SWIFTPM_CACHE_DIR" \
    --scratch-path "$package_path/.build" \
    --build-tests
  bin_dir="$(swift build \
    --package-path "$package_path" \
    --cache-path "$MARROWCHAT_SWIFTPM_CACHE_DIR" \
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
    --cache-path "$MARROWCHAT_SWIFTPM_CACHE_DIR" \
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
    run_tests "$ROOT_DIR/Packages/MarrowChatModels"
    run_tests "$ROOT_DIR/Packages/DiscordProtocol"
    run_tests "$ROOT_DIR/Packages/MarrowChatPersistence"
    run_tests "$ROOT_DIR/Packages/MessageRendering"
    run_tests "$ROOT_DIR/Packages/MediaPipeline"
    run_tests "$ROOT_DIR/Packages/MarrowChatPluginSDK"
    run_tests "$ROOT_DIR/App"
    ;;
  *)
    echo "usage: $0 [app|protocol|all]" >&2
    exit 2
    ;;
esac
