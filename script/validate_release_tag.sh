#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 SNAPSHOT_ROOT vMAJOR.MINOR.PATCH" >&2
  exit 2
fi

SNAPSHOT_ROOT="$1"
TAG="$2"

# shellcheck source=release_metadata.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release_metadata.sh"

if ! sakuracord_is_release_tag "$TAG"; then
  echo "Pre-release validation: $TAG is not a stable or nightly release tag." >&2
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
