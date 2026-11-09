#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=runtime.sh
source "$ROOT_DIR/script/runtime.sh"

TARGET="${1:-app}"
sakuracord_acquire_operation_lock
trap sakuracord_release_operation_lock EXIT

run_tests() {
  local package_path="$1"
  local bin_dir
  local framework
  local checkout

  if [[ "${SAKURACORD_STABLE_MTIMES:-}" == "1" ]]; then
    echo "=== $(basename "$package_path"): stabilize dependency file times ==="
    swift package \
      --package-path "$package_path" \
      --cache-path "$SAKURACORD_SWIFTPM_CACHE_DIR" \
      --scratch-path "$package_path/.build" \
      resolve
    for checkout in "$package_path"/.build/checkouts/*/; do
      [[ -e "$checkout/.git" ]] || continue
      python3 -I "$ROOT_DIR/script/stabilize_mtimes.py" "$checkout"
    done
  fi

  echo "=== $(basename "$package_path"): build tests ==="
  swift build \
    --package-path "$package_path" \
    --cache-path "$SAKURACORD_SWIFTPM_CACHE_DIR" \
    --scratch-path "$package_path/.build" \
    --build-tests
  echo "=== $(basename "$package_path"): locate test products ==="
  bin_dir="$(swift build \
    --package-path "$package_path" \
    --cache-path "$SAKURACORD_SWIFTPM_CACHE_DIR" \
    --scratch-path "$package_path/.build" \
    --show-bin-path)"

  # SwiftPM does not stage binary-target frameworks where its macOS test
  # helper searches for them. Keep the test host self-contained without
  # changing the application bundle or a global dynamic-library path.
  echo "=== $(basename "$package_path"): stage test frameworks ==="
  for framework in "$bin_dir"/*.framework; do
    [[ -d "$framework" ]] || continue
    mkdir -p "$bin_dir/PackageFrameworks"
    ditto "$framework" "$bin_dir/PackageFrameworks/$(basename "$framework")"
  done

  python3 "$ROOT_DIR/script/run_test_diagnostics.py" \
    --label "$(basename "$package_path")" \
    --output-dir "$SAKURACORD_RUNTIME_DIR/test-diagnostics" \
    --events --timeout-seconds 180 -- \
    swift test \
    --package-path "$package_path" \
    --cache-path "$SAKURACORD_SWIFTPM_CACHE_DIR" \
    --scratch-path "$package_path/.build" \
    --skip-build
}

run_package_tests() {
  run_tests "$ROOT_DIR/Packages/SakuraCordModels"
  run_tests "$ROOT_DIR/Packages/DiscordProtocol"
  run_tests "$ROOT_DIR/Packages/SakuraCordPersistence"
  run_tests "$ROOT_DIR/Packages/MessageRendering"
  run_tests "$ROOT_DIR/Packages/DaveKit"
  run_tests "$ROOT_DIR/Packages/MediaPipeline"
  run_tests "$ROOT_DIR/Packages/SakuraCordPluginSDK"
}

# TEMPORARY EXPERIMENT (do not merge): repeat the App suite to capture
# timeline layout preparation diagnostics, then fail so no build is published.
case "$TARGET" in
  app)
    run_tests "$ROOT_DIR/App" || true
    for i in $(seq 2 15); do
      echo "=== EXPERIMENT App run $i ==="
      python3 "$ROOT_DIR/script/run_test_diagnostics.py" --label "App-$i" \
        --output-dir "$SAKURACORD_RUNTIME_DIR/test-diagnostics" --events --timeout-seconds 180 -- \
        swift test --package-path "$ROOT_DIR/App" --cache-path "$SAKURACORD_SWIFTPM_CACHE_DIR" \
        --scratch-path "$ROOT_DIR/App/.build" --skip-build || true
    done
    echo "Experiment finished; failing deliberately." >&2
    exit 1
    ;;
  protocol|dave|media|packages|packages-core)
    echo "Experiment branch: only the app suite runs." >&2
    exit 1
    ;;
  protocol)
    run_tests "$ROOT_DIR/Packages/DiscordProtocol"
    ;;
  dave)
    run_tests "$ROOT_DIR/Packages/DaveKit"
    ;;
  media)
    run_tests "$ROOT_DIR/Packages/MediaPipeline"
    ;;
  packages)
    run_package_tests
    ;;
  packages-core)
    run_tests "$ROOT_DIR/Packages/SakuraCordModels"
    run_tests "$ROOT_DIR/Packages/SakuraCordPersistence"
    run_tests "$ROOT_DIR/Packages/MessageRendering"
    run_tests "$ROOT_DIR/Packages/SakuraCordPluginSDK"
    ;;
  all)
    run_package_tests
    run_tests "$ROOT_DIR/App"
    ;;
  *)
    echo "usage: $0 [app|protocol|dave|media|packages|packages-core|all]" >&2
    exit 2
    ;;
esac
