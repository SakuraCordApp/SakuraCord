#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=debug_credentials_config.sh
source "$ROOT_DIR/script/debug_credentials_config.sh"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sakuracord-debug-credentials-test.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT
git -C "$TEMP_ROOT" init -q

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_resolution() {
  local expected_value="$1"
  local expected_source="$2"

  sakuracord_resolve_insecure_debug_credentials "$TEMP_ROOT"
  [[ "$SAKURACORD_RESOLVED_INSECURE_DEBUG_CREDENTIALS" == "$expected_value" ]] \
    || fail "expected value $expected_value, got $SAKURACORD_RESOLVED_INSECURE_DEBUG_CREDENTIALS"
  [[ "$SAKURACORD_INSECURE_DEBUG_CREDENTIALS_SOURCE" == "$expected_source" ]] \
    || fail "expected source '$expected_source', got '$SAKURACORD_INSECURE_DEBUG_CREDENTIALS_SOURCE'"
}

unset SAKURACORD_INSECURE_DEBUG_CREDENTIALS
assert_resolution 0 default

SAKURACORD_ROOT_DIR="$TEMP_ROOT" "$ROOT_DIR/script/debug_credentials.sh" enable >/dev/null
assert_resolution 1 "repository config"

SAKURACORD_INSECURE_DEBUG_CREDENTIALS=0
assert_resolution 0 environment

SAKURACORD_INSECURE_DEBUG_CREDENTIALS=1
assert_resolution 1 environment

SAKURACORD_INSECURE_DEBUG_CREDENTIALS=invalid
if (sakuracord_resolve_insecure_debug_credentials "$TEMP_ROOT") >/dev/null 2>&1; then
  fail "invalid environment value was accepted"
fi

unset SAKURACORD_INSECURE_DEBUG_CREDENTIALS
assert_resolution 1 "repository config"
for release_mode in package-release run-release; do
  unset SAKURACORD_INSECURE_DEBUG_CREDENTIALS
  assert_resolution 1 "repository config"
  sakuracord_apply_secure_release_credential_policy "$release_mode" 0
  [[ "$SAKURACORD_RESOLVED_INSECURE_DEBUG_CREDENTIALS" == "0" ]] \
    || fail "$release_mode retained repository debug preference"
  [[ "$SAKURACORD_INSECURE_DEBUG_CREDENTIALS_SOURCE" == "release safety override" ]] \
    || fail "$release_mode safety override source was not reported"

  SAKURACORD_INSECURE_DEBUG_CREDENTIALS=1
  sakuracord_resolve_insecure_debug_credentials "$TEMP_ROOT"
  if (sakuracord_apply_secure_release_credential_policy "$release_mode" 0) \
    >/dev/null 2>&1; then
    fail "$release_mode accepted explicit insecure environment override"
  fi
done

unset SAKURACORD_INSECURE_DEBUG_CREDENTIALS
SAKURACORD_ROOT_DIR="$TEMP_ROOT" "$ROOT_DIR/script/debug_credentials.sh" disable >/dev/null
assert_resolution 0 "repository config"

git -C "$TEMP_ROOT" config --local \
  "$SAKURACORD_INSECURE_DEBUG_CREDENTIALS_CONFIG_KEY" not-a-boolean
if (sakuracord_resolve_insecure_debug_credentials "$TEMP_ROOT") >/dev/null 2>&1; then
  fail "invalid repository boolean was accepted"
fi

DEBUG_CREDENTIAL_DIRECTORY="$TEMP_ROOT/InsecureDebugCredentials"
mkdir -p "$DEBUG_CREDENTIAL_DIRECTORY"
printf 'first' >"$DEBUG_CREDENTIAL_DIRECTORY/123.credential"
printf 'second' >"$DEBUG_CREDENTIAL_DIRECTORY/456.credential"
printf 'preserve' >"$DEBUG_CREDENTIAL_DIRECTORY/unexpected.txt"
sakuracord_delete_insecure_debug_credentials "$DEBUG_CREDENTIAL_DIRECTORY"
[[ "$SAKURACORD_DELETED_DEBUG_CREDENTIAL_COUNT" == "2" ]] \
  || fail "expected two deleted debug credential files"
[[ ! -e "$DEBUG_CREDENTIAL_DIRECTORY/123.credential" \
  && ! -e "$DEBUG_CREDENTIAL_DIRECTORY/456.credential" ]] \
  || fail "debug credential files were retained"
[[ -f "$DEBUG_CREDENTIAL_DIRECTORY/unexpected.txt" ]] \
  || fail "unexpected debug credential directory entry was deleted"

rm -f "$DEBUG_CREDENTIAL_DIRECTORY/unexpected.txt"
sakuracord_delete_insecure_debug_credentials "$DEBUG_CREDENTIAL_DIRECTORY"
[[ ! -e "$DEBUG_CREDENTIAL_DIRECTORY" ]] \
  || fail "empty debug credential directory was retained"

ln -s "$TEMP_ROOT" "$DEBUG_CREDENTIAL_DIRECTORY"
if (sakuracord_delete_insecure_debug_credentials "$DEBUG_CREDENTIAL_DIRECTORY") >/dev/null 2>&1; then
  fail "symlinked debug credential directory was accepted"
fi
rm "$DEBUG_CREDENTIAL_DIRECTORY"

echo "Debug credential configuration tests passed."
