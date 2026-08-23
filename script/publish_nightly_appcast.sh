#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=release_metadata.sh
source "$ROOT_DIR/script/release_metadata.sh"

APPCAST_PATH="${1:-$ROOT_DIR/dist/appcast.xml}"
RELEASE_TAG="${SAKURACORD_RELEASE_TAG:-${GITHUB_REF_NAME:-}}"
REPOSITORY="${GITHUB_REPOSITORY:-}"
BRANCH="nightly-feed"

if ! sakuracord_is_nightly_release_tag "$RELEASE_TAG"; then
  echo "Only vMAJOR.MINOR.PATCH-beta.NUMBER releases may publish the nightly feed." >&2
  exit 2
fi
if [[ -z "$REPOSITORY" || -z "${GH_TOKEN:-}" ]]; then
  echo "GITHUB_REPOSITORY and GH_TOKEN are required to publish the nightly feed." >&2
  exit 2
fi
if [[ ! -f "$APPCAST_PATH" ]]; then
  echo "Missing nightly appcast: $APPCAST_PATH" >&2
  exit 2
fi

xmllint --noout "$APPCAST_PATH"
NEW_BUILD="$(
  xmllint --xpath \
    'string((//*[local-name()="item"])[1]/*[local-name()="version"])' \
    "$APPCAST_PATH"
)"
NEW_ENCLOSURE_URL="$(
  xmllint --xpath \
    'string((//*[local-name()="enclosure"])[1]/@url)' \
    "$APPCAST_PATH"
)"
if [[ ! "$NEW_BUILD" =~ ^[0-9]+$ ]]; then
  echo "The nightly appcast has an invalid build number." >&2
  exit 1
fi
if [[ "$NEW_ENCLOSURE_URL" != \
  "https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/"* ]]; then
  echo "The nightly appcast does not point to $RELEASE_TAG." >&2
  exit 1
fi

if ! gh api "repos/$REPOSITORY/git/ref/heads/$BRANCH" >/dev/null 2>&1; then
  SOURCE_SHA="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  gh api --method POST "repos/$REPOSITORY/git/refs" \
    -f ref="refs/heads/$BRANCH" \
    -f sha="$SOURCE_SHA" >/dev/null
fi

CURRENT_SHA=""
CURRENT_METADATA="$(
  gh api "repos/$REPOSITORY/contents/appcast.xml?ref=$BRANCH" 2>/dev/null || true
)"
if [[ -n "$CURRENT_METADATA" ]]; then
  CURRENT_SHA="$(jq -r '.sha // empty' <<< "$CURRENT_METADATA")"
  CURRENT_URL="$(jq -r '.download_url // empty' <<< "$CURRENT_METADATA")"
  if [[ -n "$CURRENT_URL" ]]; then
    CURRENT_APPCAST="$(mktemp "${TMPDIR:-/tmp}/SakuraCordNightlyAppcast.XXXXXX")"
    cleanup() {
      rm -f "$CURRENT_APPCAST"
    }
    trap cleanup EXIT
    curl --fail --location --retry 3 --output "$CURRENT_APPCAST" "$CURRENT_URL"
    CURRENT_BUILD="$(
      xmllint --xpath \
        'string((//*[local-name()="item"])[1]/*[local-name()="version"])' \
        "$CURRENT_APPCAST"
    )"
    if [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] && (( CURRENT_BUILD > NEW_BUILD )); then
      echo "Kept newer nightly feed build $CURRENT_BUILD instead of build $NEW_BUILD."
      exit 0
    fi
  fi
fi

ENCODED_APPCAST="$(base64 < "$APPCAST_PATH" | tr -d '\n')"
API_ARGUMENTS=(
  --method PUT
  "repos/$REPOSITORY/contents/appcast.xml"
  -f message="Publish $RELEASE_TAG Sparkle feed [skip ci]"
  -f content="$ENCODED_APPCAST"
  -f branch="$BRANCH"
)
if [[ -n "$CURRENT_SHA" ]]; then
  API_ARGUMENTS+=(-f sha="$CURRENT_SHA")
fi
gh api "${API_ARGUMENTS[@]}" >/dev/null

PUBLISHED_APPCAST="$(mktemp "${TMPDIR:-/tmp}/SakuraCordPublishedNightlyAppcast.XXXXXX")"
cleanup() {
  rm -f "${CURRENT_APPCAST:-}" "$PUBLISHED_APPCAST"
}
trap cleanup EXIT
RAW_URL="https://raw.githubusercontent.com/$REPOSITORY/$BRANCH/appcast.xml"
curl --fail --location --retry 5 --retry-all-errors --retry-delay 2 \
  --output "$PUBLISHED_APPCAST" \
  "$RAW_URL?run=${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
cmp "$APPCAST_PATH" "$PUBLISHED_APPCAST"
printf 'Published and verified %s at %s.\n' "$RELEASE_TAG" "$RAW_URL"
