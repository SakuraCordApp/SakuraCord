#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime.sh
source "$ROOT_DIR/script/runtime.sh"

MODE="${1:-all}"
case "$MODE" in
  all|checks|packages|packages-core|protocol|media|app) ;;
  *)
    echo "usage: $0 [all|checks|packages|packages-core|protocol|media|app]" >&2
    exit 2
    ;;
esac

# Hosted CI opts in so restored build outputs match the fresh checkout.
if [[ "${SAKURACORD_STABLE_MTIMES:-}" == "1" ]]; then
  python3 -I "$ROOT_DIR/script/stabilize_mtimes.py" "$ROOT_DIR"
fi

run_checks() {
  "$ROOT_DIR/script/code_quality.sh" check
  "$ROOT_DIR/script/test_code_quality.sh"
  "$ROOT_DIR/script/test_release_metadata.sh"
  "$ROOT_DIR/script/test_sync_main_into_nightly.sh"
  "$ROOT_DIR/script/test_debug_credentials_config.sh"
  "$ROOT_DIR/script/test_performance_benchmark.sh"
  python3 "$ROOT_DIR/script/test_run_test_diagnostics.py"
  node --test "$ROOT_DIR/script/release_automation.test.mjs"
  node --test "$ROOT_DIR/script/release_hotfix.test.mjs"
  node --test "$ROOT_DIR/script/ci_reuse.test.mjs"
  node --test "$ROOT_DIR/script/pr_builds.test.mjs"
  python3 "$ROOT_DIR/script/test_pr_build_archive.py"
  node --test "$ROOT_DIR/script/update_appcast_display_version.test.mjs"
  "$ROOT_DIR/script/test_release_tag_guard.sh"

  CREDENTIAL_PATTERN='(Authorization:[[:space:]]*(Bot|Bearer)?[[:space:]]*[A-Za-z0-9._-]{24,}|mfa\.[A-Za-z0-9_-]{20,})'
  if command -v rg >/dev/null 2>&1; then
    CREDENTIAL_SCAN=(rg -n --hidden -g '!README.md' -g '!script/ci.sh' -g '!.git/**' -g '!.build/**' -g '!.codex-runtime/**')
  else
    CREDENTIAL_SCAN=(grep -REnI --exclude=README.md --exclude=ci.sh --exclude-dir=.git --exclude-dir=.build --exclude-dir=.codex-runtime)
  fi

  if "${CREDENTIAL_SCAN[@]}" "$CREDENTIAL_PATTERN" "$ROOT_DIR"; then
    echo "Potential credential material found." >&2
    exit 1
  fi
}

case "$MODE" in
  checks)
    run_checks
    exit 0
    ;;
  packages|packages-core)
    run_checks
    "$ROOT_DIR/script/test.sh" "$MODE"
    exit 0
    ;;
  protocol)
    "$ROOT_DIR/script/test.sh" protocol
    exit 0
    ;;
  media)
    "$ROOT_DIR/script/test.sh" dave
    "$ROOT_DIR/script/test.sh" media
    exit 0
    ;;
  app)
    TEST_TARGET=app
    ;;
  all)
    run_checks
    TEST_TARGET=all
    ;;
esac

for attempt in 1 2 3; do
  if swift package \
    --package-path "$SAKURACORD_PACKAGE_DIR" \
    --cache-path "$SAKURACORD_SWIFTPM_CACHE_DIR" \
    --scratch-path "$SAKURACORD_SCRATCH_DIR" \
    resolve; then
    break
  fi
  if [[ "$attempt" -eq 3 ]]; then
    echo "Dependency resolution failed after $attempt attempts." >&2
    exit 1
  fi
  echo "Dependency resolution failed; retrying ($attempt/3)..." >&2
  sleep $((attempt * 5))
done

"$ROOT_DIR/script/test.sh" "$TEST_TARGET"

swift build \
  --package-path "$SAKURACORD_PACKAGE_DIR" \
  --cache-path "$SAKURACORD_SWIFTPM_CACHE_DIR" \
  --scratch-path "$SAKURACORD_SCRATCH_DIR" \
  --product SakuraCord
