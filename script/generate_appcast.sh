#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=runtime.sh
source "$ROOT_DIR/script/runtime.sh"
# shellcheck source=release_metadata.sh
source "$ROOT_DIR/script/release_metadata.sh"

RELEASE_TAG="${SAKURACORD_RELEASE_TAG:-${GITHUB_REF_NAME:-}}"
if ! sakuracord_is_release_tag "$RELEASE_TAG"; then
  echo "SAKURACORD_RELEASE_TAG or GITHUB_REF_NAME must use vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-Beta-NUMBER." >&2
  exit 2
fi
if [[ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  echo "SPARKLE_ED_PRIVATE_KEY is required to sign the update archive and appcast." >&2
  exit 2
fi

RELEASE_VERSION="$(sakuracord_release_version "$ROOT_DIR")"
DMG_NAME="$(sakuracord_release_dmg_name_from_tag "$RELEASE_TAG")"
DMG_PATH="${1:-$ROOT_DIR/dist/$DMG_NAME}"
OUTPUT_PATH="${2:-$ROOT_DIR/dist/appcast.xml}"
RELEASE_NOTES_PATH="${3:-${SAKURACORD_RELEASE_NOTES_PATH:-}}"
if [[ "$DMG_PATH" != /* ]]; then
  DMG_PATH="$ROOT_DIR/$DMG_PATH"
fi
if [[ "$OUTPUT_PATH" != /* ]]; then
  OUTPUT_PATH="$ROOT_DIR/$OUTPUT_PATH"
fi
if [[ -n "$RELEASE_NOTES_PATH" && "$RELEASE_NOTES_PATH" != /* ]]; then
  RELEASE_NOTES_PATH="$ROOT_DIR/$RELEASE_NOTES_PATH"
fi
if [[ ! -f "$DMG_PATH" ]]; then
  echo "Missing release archive: $DMG_PATH" >&2
  exit 1
fi
if [[ -z "$RELEASE_NOTES_PATH" || ! -s "$RELEASE_NOTES_PATH" ]]; then
  echo "A non-empty validated release-notes file is required." >&2
  exit 1
fi

GENERATE_APPCAST="$(
  find "$SAKURACORD_SCRATCH_DIR/artifacts" \
    -type f -path '*/bin/generate_appcast' -perm -u+x -print -quit 2>/dev/null
)"
SIGN_UPDATE="$(
  find "$SAKURACORD_SCRATCH_DIR/artifacts" \
    -type f -path '*/bin/sign_update' -perm -u+x -print -quit 2>/dev/null
)"
if [[ -z "$GENERATE_APPCAST" || -z "$SIGN_UPDATE" ]]; then
  echo "Sparkle release tools were not found in the resolved SwiftPM artifacts." >&2
  echo "Build the App package before generating an appcast." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
STAGING_DIR="$(mktemp -d "$SAKURACORD_DIST_DIR/SparkleAppcast.XXXXXX")"
cleanup() {
  rm -R "$STAGING_DIR"
}
trap cleanup EXIT

ditto "$DMG_PATH" "$STAGING_DIR/$DMG_NAME"
{
  printf '# SakuraCord %s\n\n' "$RELEASE_TAG"
  cat "$RELEASE_NOTES_PATH"
} >"$STAGING_DIR/${DMG_NAME%.dmg}.md"

DOWNLOAD_URL_PREFIX="https://github.com/SakuraCordApp/SakuraCord/releases/download/$RELEASE_TAG/"
RELEASE_URL="https://github.com/SakuraCordApp/SakuraCord/releases/tag/$RELEASE_TAG"
printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | "$GENERATE_APPCAST" \
  --ed-key-file - \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --embed-release-notes \
  --full-release-notes-url "$RELEASE_URL" \
  --link "$RELEASE_URL" \
  --maximum-deltas 0 \
  -o "$OUTPUT_PATH" \
  "$STAGING_DIR"

if sakuracord_is_nightly_release_tag "$RELEASE_TAG"; then
  node "$ROOT_DIR/script/update_appcast_display_version.mjs" \
    "$OUTPUT_PATH" "$RELEASE_TAG"
  printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | \
    "$SIGN_UPDATE" --ed-key-file - "$OUTPUT_PATH" >/dev/null
fi

SPARKLE_SIGN_UPDATE="$SIGN_UPDATE" \
  "$ROOT_DIR/script/validate_appcast.sh" "$OUTPUT_PATH" "$DMG_PATH"

printf 'Created and verified %s\n' "$OUTPUT_PATH"
