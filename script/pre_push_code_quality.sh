#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
SNAPSHOT_PARENT="$ROOT_DIR/.build/pre-push-snapshots"
mkdir -p "$SNAPSHOT_PARENT"
TEMP_ROOT="$(mktemp -d "$SNAPSHOT_PARENT/run.XXXXXX")"
ZERO_SHA="0000000000000000000000000000000000000000"
SEEN_SHAS=""
CHECKED_REF_COUNT=0

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

check_snapshot() {
  local snapshot_root="$1"
  local label="$2"

  "$ROOT_DIR/script/check_code_quality_snapshot.sh" \
    "$snapshot_root" \
    "Pre-push code quality: $label"
}

check_commit() {
  local sha="$1"
  local snapshot_root="$TEMP_ROOT/commit-$sha"

  if [[ "$SEEN_SHAS" == *"|$sha|"* ]]; then
    return
  fi
  SEEN_SHAS="$SEEN_SHAS|$sha|"

  mkdir -p "$snapshot_root"
  git archive "$sha" | tar -x -C "$snapshot_root"
  check_snapshot "$snapshot_root" "committed tree $sha"
  CHECKED_REF_COUNT=$((CHECKED_REF_COUNT + 1))
}

while read -r local_ref local_sha remote_ref remote_sha; do
  if [[ -z "${local_ref:-}" || "$local_sha" == "$ZERO_SHA" ]]; then
    continue
  fi
  check_commit "$local_sha"
done

if ! git diff --cached --quiet --diff-filter=ACMR -- '*.swift'; then
  INDEX_ROOT="$TEMP_ROOT/index"
  mkdir -p "$INDEX_ROOT"
  git checkout-index --all --prefix="$INDEX_ROOT/"
  check_snapshot "$INDEX_ROOT" "staged Swift snapshot"
fi

if [[ "$CHECKED_REF_COUNT" -eq 0 ]] \
  && git diff --cached --quiet --diff-filter=ACMR -- '*.swift'; then
  echo "Pre-push code quality: no pushed ref or staged Swift change required checking."
fi
