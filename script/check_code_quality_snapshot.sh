#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: $0 <snapshot root> <label>" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TOOLS_DIR="$ROOT_DIR/.build/code-quality-tools"
SNAPSHOT_ROOT="$1"
LABEL="$2"

echo "$LABEL"
SAKURACORD_CODE_QUALITY_ROOT="$SNAPSHOT_ROOT" \
  SAKURACORD_CODE_QUALITY_TOOLS_DIR="$TOOLS_DIR" \
  "$ROOT_DIR/script/code_quality.sh" check
