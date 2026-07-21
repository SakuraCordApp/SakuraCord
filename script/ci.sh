#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if command -v swiftformat >/dev/null 2>&1; then
  swiftformat "$ROOT_DIR/App" "$ROOT_DIR/Packages" --config "$ROOT_DIR/.swiftformat" --lint
fi

if command -v swiftlint >/dev/null 2>&1; then
  swiftlint lint --strict --config "$ROOT_DIR/.swiftlint.yml"
fi

CREDENTIAL_PATTERN='(Authorization:[[:space:]]*(Bot|Bearer)?[[:space:]]*[A-Za-z0-9._-]{24,}|mfa\.[A-Za-z0-9_-]{20,})'
if command -v rg >/dev/null 2>&1; then
  CREDENTIAL_SCAN=(rg -n --hidden -g '!README.md' -g '!script/ci.sh' -g '!.git/**' -g '!.build/**')
else
  CREDENTIAL_SCAN=(grep -REnI --exclude=README.md --exclude=ci.sh --exclude-dir=.git --exclude-dir=.build)
fi

if "${CREDENTIAL_SCAN[@]}" "$CREDENTIAL_PATTERN" "$ROOT_DIR"; then
  echo "Potential credential material found." >&2
  exit 1
fi

for attempt in 1 2 3; do
  if swift package --package-path "$ROOT_DIR/App" resolve; then
    break
  fi
  if [[ "$attempt" -eq 3 ]]; then
    echo "Dependency resolution failed after $attempt attempts." >&2
    exit 1
  fi
  echo "Dependency resolution failed; retrying ($attempt/3)..." >&2
  sleep $((attempt * 5))
done

swift build --package-path "$ROOT_DIR/App" --product SakuraCord
