#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=runtime.sh
source "$ROOT_DIR/script/runtime.sh"
# shellcheck source=release_metadata.sh
source "$ROOT_DIR/script/release_metadata.sh"

DMGBUILD="${DMGBUILD:-dmgbuild}"
RELEASE_VERSION="$(sakuracord_release_version "$ROOT_DIR")"
RELEASE_TAG="${SAKURACORD_RELEASE_TAG:-}"
if [[ -n "$RELEASE_TAG" ]]; then
  DMG_NAME="$(sakuracord_release_dmg_name_from_tag "$RELEASE_TAG")"
else
  DMG_NAME="$(sakuracord_release_dmg_name "$RELEASE_VERSION")"
fi
OUTPUT_PATH="${1:-$ROOT_DIR/dist/$DMG_NAME}"
SETTINGS="$ROOT_DIR/App/Packaging/DMG/settings.py"

if [[ "$OUTPUT_PATH" != /* ]]; then
  OUTPUT_PATH="$ROOT_DIR/$OUTPUT_PATH"
fi

if [[ ! -x "$DMGBUILD" ]] && ! command -v "$DMGBUILD" >/dev/null 2>&1; then
  echo "dmgbuild is required. Install it with: python3 -m pip install dmgbuild==1.6.7" >&2
  exit 1
fi

"$ROOT_DIR/script/build_and_run.sh" package-release
codesign --verify --deep --strict --verbose=2 "$SAKURACORD_APP_BUNDLE"

mkdir -p "$(dirname "$OUTPUT_PATH")"
DMG_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/SakuraCordDMG.XXXXXX")"
cleanup() {
  rm -R "$DMG_TEMP_DIR"
}
trap cleanup EXIT

export SAKURACORD_DMG_APP_BUNDLE="$SAKURACORD_APP_BUNDLE"
export SAKURACORD_DMG_BACKGROUND="$ROOT_DIR/App/Packaging/DMG/background.png"
"$DMGBUILD" -s "$SETTINGS" SakuraCord "$DMG_TEMP_DIR/$DMG_NAME"
hdiutil verify "$DMG_TEMP_DIR/$DMG_NAME"
rm -f "$OUTPUT_PATH"
mv "$DMG_TEMP_DIR/$DMG_NAME" "$OUTPUT_PATH"

printf 'Created %s\n' "$OUTPUT_PATH"
shasum -a 256 "$OUTPUT_PATH"
