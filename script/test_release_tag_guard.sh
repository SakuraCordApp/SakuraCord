#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TEMP_ROOT/script" "$TEMP_ROOT/Releases"
cp "$ROOT_DIR/script/release_automation.mjs" "$TEMP_ROOT/script/release_automation.mjs"

if "$ROOT_DIR/script/validate_release_tag.sh" "$TEMP_ROOT" v0.1.3 >/dev/null 2>&1; then
  echo "Release tag validation accepted a missing release-copy file." >&2
  exit 1
fi

printf '%s\n' \
  '{' \
  '  "schemaVersion": 1,' \
  '  "tagName": "v0.1.2",' \
  '  "githubDescription": "Reviewed GitHub notes.",' \
  '  "discordAnnouncement": "**Reviewed feature 🌸**\n\n**Highlights**\n- Reviewed highlight"' \
  '}' > "$TEMP_ROOT/Releases/v0.1.3.json"

if "$ROOT_DIR/script/validate_release_tag.sh" "$TEMP_ROOT" v0.1.3 >/dev/null 2>&1; then
  echo "Release tag validation accepted copy for another tag." >&2
  exit 1
fi

printf '%s\n' \
  '{' \
  '  "schemaVersion": 1,' \
  '  "tagName": "v0.1.3",' \
  '  "githubDescription": "Reviewed GitHub notes.",' \
  '  "discordAnnouncement": "**Reviewed feature 🌸**\n\n**Highlights**\n- Reviewed highlight"' \
  '}' > "$TEMP_ROOT/Releases/v0.1.3.json"

"$ROOT_DIR/script/validate_release_tag.sh" "$TEMP_ROOT" v0.1.3 >/dev/null

HOOK_REPO="$TEMP_ROOT/hook-repo"
mkdir -p "$HOOK_REPO/script" "$HOOK_REPO/Releases"
cp "$ROOT_DIR/script/pre_push_code_quality.sh" "$HOOK_REPO/script/"
cp "$ROOT_DIR/script/validate_release_tag.sh" "$HOOK_REPO/script/"
cp "$ROOT_DIR/script/release_automation.mjs" "$HOOK_REPO/script/"
cp "$TEMP_ROOT/Releases/v0.1.3.json" "$HOOK_REPO/Releases/"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$HOOK_REPO/script/check_code_quality_snapshot.sh"
chmod +x "$HOOK_REPO/script/"*.sh
git -C "$HOOK_REPO" init --quiet
git -C "$HOOK_REPO" config user.email release-guard@example.invalid
git -C "$HOOK_REPO" config user.name "Release Guard Test"
git -C "$HOOK_REPO" add .
git -C "$HOOK_REPO" commit --quiet -m "Release guard fixture"
HOOK_SHA="$(git -C "$HOOK_REPO" rev-parse HEAD)"
ZERO_SHA="0000000000000000000000000000000000000000"

printf 'refs/heads/main %s refs/heads/main %s\n' "$HOOK_SHA" "$ZERO_SHA" \
  | (cd "$HOOK_REPO" && "$ROOT_DIR/script/pre_push_code_quality.sh") >/dev/null
printf 'refs/heads/main %s refs/tags/v0.1.3 %s\n' "$HOOK_SHA" "$ZERO_SHA" \
  | (cd "$HOOK_REPO" && "$ROOT_DIR/script/pre_push_code_quality.sh") >/dev/null
if printf 'refs/heads/main %s refs/tags/v0.1.4 %s\n' "$HOOK_SHA" "$ZERO_SHA" \
  | (cd "$HOOK_REPO" && "$ROOT_DIR/script/pre_push_code_quality.sh") >/dev/null 2>&1; then
  echo "Pre-push validation accepted a tagged destination without its release-copy file." >&2
  exit 1
fi

echo "Release tag guard tests passed."
