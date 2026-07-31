#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
EXPECTED_HOOKS_PATH=".githooks"
CURRENT_HOOKS_PATH="$(git -C "$ROOT_DIR" config --local --get core.hooksPath || true)"

if [[ -n "$CURRENT_HOOKS_PATH" && "$CURRENT_HOOKS_PATH" != "$EXPECTED_HOOKS_PATH" ]]; then
  echo "Refusing to replace existing core.hooksPath: $CURRENT_HOOKS_PATH" >&2
  echo "Integrate $ROOT_DIR/.githooks/pre-commit and pre-push into the existing hooks path manually." >&2
  exit 1
fi

git -C "$ROOT_DIR" config --local core.hooksPath "$EXPECTED_HOOKS_PATH"
echo "Installed SakuraCord Git hooks from $EXPECTED_HOOKS_PATH."
echo "Every commit validates its staged snapshot; every push validates committed tips and staged Swift changes."
