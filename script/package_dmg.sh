#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=worktree_runtime.sh
source "$ROOT_DIR/script/worktree_runtime.sh"

if [[ "$SAKURACORD_IS_MAIN_WORKTREE" -ne 1 ]]; then
  echo "Release DMGs must be built from the main checkout, not a linked worktree." >&2
  exit 2
fi

DMGBUILD="${DMGBUILD:-dmgbuild}"
OUTPUT_PATH="${1:-$ROOT_DIR/dist/SakuraCord.dmg}"
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
"$DMGBUILD" -s "$SETTINGS" SakuraCord "$DMG_TEMP_DIR/SakuraCord.dmg"
hdiutil verify "$DMG_TEMP_DIR/SakuraCord.dmg"
rm -f "$OUTPUT_PATH"
mv "$DMG_TEMP_DIR/SakuraCord.dmg" "$OUTPUT_PATH"

printf 'Created %s\n' "$OUTPUT_PATH"
shasum -a 256 "$OUTPUT_PATH"
