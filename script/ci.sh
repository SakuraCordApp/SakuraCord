#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime.sh
source "$ROOT_DIR/script/runtime.sh"

MODE="${1:-all}"
case "$MODE" in
  all|checks) ;;
  *)
    echo "usage: $0 [all|checks]" >&2
    exit 2
    ;;
esac

"$ROOT_DIR/script/code_quality.sh" check
"$ROOT_DIR/script/test_release_metadata.sh"
"$ROOT_DIR/script/test_publish_nightly_appcast.sh"
"$ROOT_DIR/script/test_debug_credentials_config.sh"
node --test "$ROOT_DIR/script/release_automation.test.mjs"
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

if [[ "$MODE" == "checks" ]]; then
  exit 0
fi

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

swift build \
  --package-path "$SAKURACORD_PACKAGE_DIR" \
  --cache-path "$SAKURACORD_SWIFTPM_CACHE_DIR" \
  --scratch-path "$SAKURACORD_SCRATCH_DIR" \
  --product SakuraCord
