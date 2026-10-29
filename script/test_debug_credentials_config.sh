#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=debug_credentials_config.sh
source "$ROOT_DIR/script/debug_credentials_config.sh"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sakuracord-debug-credentials-test.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT
export GIT_CONFIG_GLOBAL="$TEMP_ROOT/global.gitconfig"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
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

git -C "$TEMP_ROOT" config --local "$SAKURACORD_INSECURE_DEBUG_CREDENTIALS_CONFIG_KEY" false
assert_resolution 0 "legacy repository config"

SAKURACORD_ROOT_DIR="$TEMP_ROOT" "$ROOT_DIR/script/debug_credentials.sh" enable >/dev/null
assert_resolution 1 "machine config"

# A separate clone has no repository preference but must inherit the machine setting.
mkdir "$TEMP_ROOT/clone"
git -C "$TEMP_ROOT/clone" init -q
sakuracord_resolve_insecure_debug_credentials "$TEMP_ROOT/clone"
[[ "$SAKURACORD_RESOLVED_INSECURE_DEBUG_CREDENTIALS" == "1" ]] \
  || fail "separate clone lost machine preference"

SAKURACORD_INSECURE_DEBUG_CREDENTIALS=0
assert_resolution 0 environment

SAKURACORD_INSECURE_DEBUG_CREDENTIALS=1
assert_resolution 1 environment

SAKURACORD_INSECURE_DEBUG_CREDENTIALS=invalid
if (sakuracord_resolve_insecure_debug_credentials "$TEMP_ROOT") >/dev/null 2>&1; then
  fail "invalid environment value was accepted"
fi

unset SAKURACORD_INSECURE_DEBUG_CREDENTIALS
assert_resolution 1 "machine config"
sakuracord_apply_secure_release_credential_policy package 1
[[ "$SAKURACORD_RESOLVED_INSECURE_DEBUG_CREDENTIALS" == "0" ]] \
  || fail "update-enabled package retained debug preference"
# Distributable packages stay on Keychain regardless of the machine preference.
unset SAKURACORD_INSECURE_DEBUG_CREDENTIALS
assert_resolution 1 "machine config"
sakuracord_apply_secure_release_credential_policy package-release 0
[[ "$SAKURACORD_RESOLVED_INSECURE_DEBUG_CREDENTIALS" == "0" ]] \
  || fail "package-release retained machine debug preference"
[[ "$SAKURACORD_INSECURE_DEBUG_CREDENTIALS_SOURCE" == "release safety override" ]] \
  || fail "package-release safety override source was not reported"

# A local run-release honours the machine preference.
assert_resolution 1 "machine config"
sakuracord_apply_secure_release_credential_policy run-release 0
[[ "$SAKURACORD_RESOLVED_INSECURE_DEBUG_CREDENTIALS" == "1" ]] \
  || fail "run-release ignored machine debug preference"
[[ "$SAKURACORD_INSECURE_DEBUG_CREDENTIALS_SOURCE" == "machine config (local release)" ]] \
  || fail "run-release machine preference source was not reported"

# Update-enabled run-release stays on Keychain.
assert_resolution 1 "machine config"
sakuracord_apply_secure_release_credential_policy run-release 1
[[ "$SAKURACORD_RESOLVED_INSECURE_DEBUG_CREDENTIALS" == "0" ]] \
  || fail "update-enabled run-release retained machine debug preference"
[[ "$SAKURACORD_INSECURE_DEBUG_CREDENTIALS_SOURCE" == "release safety override" ]] \
  || fail "update-enabled run-release safety override source was not reported"

# Only the machine preference applies; legacy repository config does not.
git config --global --unset "$SAKURACORD_INSECURE_DEBUG_CREDENTIALS_CONFIG_KEY"
git -C "$TEMP_ROOT" config --local "$SAKURACORD_INSECURE_DEBUG_CREDENTIALS_CONFIG_KEY" true
assert_resolution 1 "legacy repository config"
sakuracord_apply_secure_release_credential_policy run-release 0
[[ "$SAKURACORD_RESOLVED_INSECURE_DEBUG_CREDENTIALS" == "0" ]] \
  || fail "run-release honoured legacy repository preference"
git -C "$TEMP_ROOT" config --local "$SAKURACORD_INSECURE_DEBUG_CREDENTIALS_CONFIG_KEY" false
SAKURACORD_ROOT_DIR="$TEMP_ROOT" "$ROOT_DIR/script/debug_credentials.sh" enable >/dev/null

# Explicit environment overrides are rejected in every release mode.
for release_mode in package-release run-release; do
  SAKURACORD_INSECURE_DEBUG_CREDENTIALS=1
  sakuracord_resolve_insecure_debug_credentials "$TEMP_ROOT"
  if (sakuracord_apply_secure_release_credential_policy "$release_mode" 0) \
    >/dev/null 2>&1; then
    fail "$release_mode accepted explicit insecure environment override"
  fi
done

# With the machine preference off, run-release uses Keychain.
unset SAKURACORD_INSECURE_DEBUG_CREDENTIALS
SAKURACORD_ROOT_DIR="$TEMP_ROOT" "$ROOT_DIR/script/debug_credentials.sh" disable >/dev/null
assert_resolution 0 "machine config"
sakuracord_apply_secure_release_credential_policy run-release 0
[[ "$SAKURACORD_RESOLVED_INSECURE_DEBUG_CREDENTIALS" == "0" ]] \
  || fail "run-release enabled credentials with machine preference off"
SAKURACORD_ROOT_DIR="$TEMP_ROOT" "$ROOT_DIR/script/debug_credentials.sh" enable >/dev/null

unset SAKURACORD_INSECURE_DEBUG_CREDENTIALS
SAKURACORD_ROOT_DIR="$TEMP_ROOT" "$ROOT_DIR/script/debug_credentials.sh" disable >/dev/null
assert_resolution 0 "machine config"

git config --global \
  "$SAKURACORD_INSECURE_DEBUG_CREDENTIALS_CONFIG_KEY" not-a-boolean
if (sakuracord_resolve_insecure_debug_credentials "$TEMP_ROOT") >/dev/null 2>&1; then
  fail "invalid machine boolean was accepted"
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

# Launch guards share the same isolated preference store. Only macOS signing
# commands are substituted; plist parsing and policy resolution remain real.
source "$ROOT_DIR/script/development_launch.sh"
SAKURACORD_ROOT_DIR="$TEMP_ROOT/clone"
SAKURACORD_APP_BUNDLE="$TEMP_ROOT/test.app"
SAKURACORD_BUNDLE_ID=dev.sakuracord.SakuraCord
mkdir -p "$SAKURACORD_APP_BUNDLE/Contents"
TEST_IDENTITY=1111111111111111111111111111111111111111
TEST_IDENTITIES="1) $TEST_IDENTITY \"SakuraCord Local Development\""
TEST_SIGNATURE_VALID=1
unset SAKURACORD_CODE_SIGN_IDENTITY
security() { printf '%s\n' "$TEST_IDENTITIES"; }
codesign() { [[ "$TEST_SIGNATURE_VALID" == "1" ]]; }
write_test_plist() {
  python3 - "$SAKURACORD_APP_BUNDLE/Contents/Info.plist" "$1" "${2:-debug}" "${3:-0}" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "wb") as stream:
    plistlib.dump({
        "SakuraCordInsecureDebugCredentialsEnabled": sys.argv[2] == "1",
        "SakuraCordBuildConfiguration": sys.argv[3],
        "SakuraCordUpdatesEnabled": sys.argv[4] == "1",
    }, stream)
PY
}
assert_launch_refused() {
  if (sakuracord_verify_development_launch) >"$TEMP_ROOT/refusal.log" 2>&1; then
    fail "launch accepted: $1"
  fi
}

sakuracord_set_persistent_debug_credentials true
write_test_plist 0
assert_launch_refused "stale bundle credential mode"
write_test_plist 1
sakuracord_verify_development_launch >/dev/null
[[ "$(git config --global --get sakuracord.codeSignIdentity)" == "$TEST_IDENTITY" ]] \
  || fail "selected signing identity was not persisted"
TEST_IDENTITIES='1) 2222222222222222222222222222222222222222 "Apple Development: Other"'
assert_launch_refused "saved certificate missing but another identity available"
TEST_IDENTITIES="1) $TEST_IDENTITY \"SakuraCord Local Development\""
TEST_SIGNATURE_VALID=0
assert_launch_refused "invalid or differently signed bundle"
TEST_SIGNATURE_VALID=1
SAKURACORD_CODE_SIGN_IDENTITY=-
assert_launch_refused "ad-hoc signing selected"
unset SAKURACORD_CODE_SIGN_IDENTITY
write_test_plist 0 release
sakuracord_verify_development_launch >/dev/null
write_test_plist 1 release
sakuracord_verify_development_launch >/dev/null
write_test_plist 1 release 1
assert_launch_refused "update-enabled release bundle with insecure credentials"
write_test_plist 1 release 0
SAKURACORD_INSECURE_DEBUG_CREDENTIALS=1
assert_launch_refused "release bundle with explicit insecure environment override"
unset SAKURACORD_INSECURE_DEBUG_CREDENTIALS
write_test_plist 1 release 0
sakuracord_set_persistent_debug_credentials false
assert_launch_refused "release bundle with insecure credentials while machine preference is off"

echo "Debug credential configuration tests passed."
