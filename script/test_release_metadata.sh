#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=release_metadata.sh
source "$ROOT_DIR/script/release_metadata.sh"

EXPECTED_NAME="SakuraCord.v0.1.0.dmg"
ACTUAL_NAME="$(sakuracord_release_dmg_name "0.1.0")"
ACTUAL_URL_NAME="$(sakuracord_release_dmg_url_name "0.1.0")"

if [[ "$ACTUAL_NAME" != "$EXPECTED_NAME" ]]; then
  echo "Unexpected release DMG name: $ACTUAL_NAME" >&2
  exit 1
fi
if [[ "$ACTUAL_URL_NAME" != "$EXPECTED_NAME" ]]; then
  echo "Unexpected release DMG URL name: $ACTUAL_URL_NAME" >&2
  exit 1
fi
if [[ "$ACTUAL_NAME" == *" "* || "$ACTUAL_NAME" == *"%"* ]]; then
  echo "Release asset names must not be normalized by GitHub." >&2
  exit 1
fi
if sakuracord_release_dmg_name "0.1" >/dev/null 2>&1; then
  echo "Invalid release versions must be rejected." >&2
  exit 1
fi

printf 'Release metadata tests passed.\n'
