#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
SNAPSHOT_PARENT="$ROOT_DIR/.build/pre-commit-snapshots"
mkdir -p "$SNAPSHOT_PARENT"
TEMP_ROOT="$(mktemp -d "$SNAPSHOT_PARENT/run.XXXXXX")"

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

INDEX_ROOT="$TEMP_ROOT/index"
mkdir -p "$INDEX_ROOT"
git checkout-index --all --prefix="$INDEX_ROOT/"

"$ROOT_DIR/script/check_code_quality_snapshot.sh" \
  "$INDEX_ROOT" \
  "Pre-commit code quality: staged index snapshot"
