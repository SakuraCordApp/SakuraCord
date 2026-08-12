#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 SNAPSHOT_ROOT vMAJOR.MINOR.PATCH" >&2
  exit 2
fi

SNAPSHOT_ROOT="$1"
TAG="$2"

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Pre-release validation: $TAG is not a vMAJOR.MINOR.PATCH tag." >&2
  exit 1
fi

RELEASE_COPY="$SNAPSHOT_ROOT/Releases/$TAG.json"
if [[ ! -f "$RELEASE_COPY" ]]; then
  echo "Pre-release validation: Releases/$TAG.json is missing from $TAG." >&2
  exit 1
fi

node "$SNAPSHOT_ROOT/script/release_automation.mjs" validate-copy \
  --input "$RELEASE_COPY" \
  --tag "$TAG"
