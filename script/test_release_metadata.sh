#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=release_metadata.sh
source "$ROOT_DIR/script/release_metadata.sh"

TEMP_REPOSITORY="$(mktemp -d)"
cleanup() {
  rm -rf "$TEMP_REPOSITORY"
}
trap cleanup EXIT

git -C "$TEMP_REPOSITORY" init -q
git -C "$TEMP_REPOSITORY" \
  -c user.name="SakuraCord Tests" \
  -c user.email="tests@sakuracord.invalid" \
  commit --allow-empty -q -m "Initial commit"
git -C "$TEMP_REPOSITORY" tag v0.2.0-Beta-7

if [[ "$(SAKURACORD_VERSION= sakuracord_release_version "$TEMP_REPOSITORY")" \
  != "0.2.0" ]]; then
  echo "Nightly tags must provide the base local bundle version." >&2
  exit 1
fi
if [[ "$(SAKURACORD_VERSION= SAKURACORD_RELEASE_TAG= \
  sakuracord_bundle_display_version "$TEMP_REPOSITORY" "0.2.0")" \
  != "0.2.0 Beta 7" ]]; then
  echo "Nightly tags must provide the local beta display version." >&2
  exit 1
fi

git -C "$TEMP_REPOSITORY" tag -d v0.2.0-Beta-7 >/dev/null
git -C "$TEMP_REPOSITORY" tag v0.2.0

if [[ "$(SAKURACORD_VERSION= sakuracord_release_version "$TEMP_REPOSITORY")" \
  != "0.2.0" ]]; then
  echo "Regular tags must provide the local bundle version." >&2
  exit 1
fi
if [[ "$(SAKURACORD_VERSION= SAKURACORD_RELEASE_TAG= \
  sakuracord_bundle_display_version "$TEMP_REPOSITORY" "0.2.0")" \
  != "0.2.0" ]]; then
  echo "Regular tags must provide the local release display version." >&2
  exit 1
fi
if [[ "$(SAKURACORD_VERSION=9.8.7 SAKURACORD_RELEASE_TAG= \
  sakuracord_bundle_display_version "$TEMP_REPOSITORY" "9.8.7")" \
  != "9.8.7" ]]; then
  echo "Explicit local versions must remain authoritative without a release tag." >&2
  exit 1
fi

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

if ! sakuracord_is_release_tag "v0.1.0" \
  || ! sakuracord_is_release_tag "v0.2.0-Beta-7" \
  || sakuracord_is_release_tag "v0.2-Beta-7" \
  || sakuracord_is_release_tag "v0.2.0-beta.7" \
  || sakuracord_is_release_tag "v0.2.0-nightly.1"; then
  echo "Release tag classification is incorrect." >&2
  exit 1
fi
if [[ "$(sakuracord_release_track_from_tag "v0.2.0")" != "regular" ]] \
  || [[ "$(sakuracord_release_track_from_tag "v0.2.0-Beta-7")" != "nightly" ]]; then
  echo "Release track classification is incorrect." >&2
  exit 1
fi
if [[ "$(sakuracord_release_version_from_tag "v0.2.0-Beta-7")" != "0.2.0" ]]; then
  echo "Nightly tags must preserve the base bundle version." >&2
  exit 1
fi
if [[ "$(sakuracord_release_dmg_name_from_tag "v0.2.0-Beta-7")" \
  != "SakuraCord-v0.2.0-Beta-7.dmg" ]]; then
  echo "Nightly release DMG names must remain tag-specific." >&2
  exit 1
fi
if [[ "$(sakuracord_release_display_name_from_tag "v0.2.0-Beta-7")" \
  != "v0.2.0 Beta 7" ]]; then
  echo "Nightly release names must use human-readable beta naming." >&2
  exit 1
fi
if [[ "$(sakuracord_release_appcast_display_version_from_tag "v0.2.0")" \
  != "0.2.0" ]] \
  || [[ "$(sakuracord_release_appcast_display_version_from_tag "v0.2.0-Beta-7")" \
    != "0.2.0 Beta 7" ]]; then
  echo "Sparkle display versions must preserve the nightly beta label." >&2
  exit 1
fi

printf 'Release metadata tests passed.\n'
