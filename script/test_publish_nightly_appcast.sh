#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

APPCAST="$TEMP_ROOT/appcast.xml"
FAKE_BIN="$TEMP_ROOT/bin"
GH_LOG="$TEMP_ROOT/gh.log"
CURL_COUNT="$TEMP_ROOT/curl-count"
mkdir -p "$FAKE_BIN"

printf '%s\n' \
  '<?xml version="1.0" encoding="utf-8"?>' \
  '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">' \
  '  <channel><item>' \
  '    <sparkle:version>42</sparkle:version>' \
  '    <enclosure url="https://github.com/SakuraCordApp/SakuraCord/releases/download/v0.2.0-Beta-3/SakuraCord-v0.2.0-Beta-3.dmg" />' \
  '  </item></channel>' \
  '</rss>' > "$APPCAST"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf '\''%s\n'\'' "$*" >> "$SAKURACORD_TEST_GH_LOG"' \
  'if [[ "$*" == *"git/ref/heads/nightly-feed"* ]]; then exit 1; fi' \
  'if [[ "$*" == *"contents/appcast.xml?ref=nightly-feed"* ]]; then exit 1; fi' \
  'exit 0' > "$FAKE_BIN/gh"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'output=""' \
  'while [[ "$#" -gt 0 ]]; do' \
  '  if [[ "$1" == "--output" ]]; then output="$2"; shift 2; else shift; fi' \
  'done' \
  'count=0' \
  'if [[ -f "$SAKURACORD_TEST_CURL_COUNT" ]]; then count="$(<"$SAKURACORD_TEST_CURL_COUNT")"; fi' \
  'count=$((count + 1))' \
  'echo "$count" > "$SAKURACORD_TEST_CURL_COUNT"' \
  'if [[ "$count" == "1" ]]; then echo stale > "$output"; else cp "$SAKURACORD_TEST_APPCAST" "$output"; fi' \
  > "$FAKE_BIN/curl"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$FAKE_BIN/sleep"
chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/curl" "$FAKE_BIN/sleep"

if PATH="$FAKE_BIN:$PATH" \
  GH_TOKEN=test-token \
  GITHUB_REPOSITORY=SakuraCordApp/SakuraCord \
  SAKURACORD_RELEASE_TAG=v0.2.0 \
  "$ROOT_DIR/script/publish_nightly_appcast.sh" "$APPCAST" >/dev/null 2>&1; then
  echo "Nightly feed publication accepted a regular release tag." >&2
  exit 1
fi

PATH="$FAKE_BIN:$PATH" \
GH_TOKEN=test-token \
GITHUB_REPOSITORY=SakuraCordApp/SakuraCord \
GITHUB_RUN_ID=123 \
SAKURACORD_RELEASE_TAG=v0.2.0-Beta-3 \
SAKURACORD_TEST_APPCAST="$APPCAST" \
SAKURACORD_TEST_GH_LOG="$GH_LOG" \
SAKURACORD_TEST_CURL_COUNT="$CURL_COUNT" \
  "$ROOT_DIR/script/publish_nightly_appcast.sh" "$APPCAST" >/dev/null

if ! grep -Fq -- "--method POST repos/SakuraCordApp/SakuraCord/git/refs" "$GH_LOG"; then
  echo "Nightly feed publication did not create its generated branch." >&2
  exit 1
fi
if ! grep -Fq -- "--method PUT repos/SakuraCordApp/SakuraCord/contents/appcast.xml" "$GH_LOG"; then
  echo "Nightly feed publication did not upload its signed appcast." >&2
  exit 1
fi
if [[ "$(<"$CURL_COUNT")" != "2" ]]; then
  echo "Nightly feed publication did not wait for the raw feed to refresh." >&2
  exit 1
fi

printf 'Nightly appcast publication tests passed.\n'
