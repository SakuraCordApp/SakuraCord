#!/usr/bin/env bash

# Shared by build-and-run and launch-only, including launches of older checkouts.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/debug_credentials_config.sh"

sakuracord_resolve_code_sign_identity() {
  local required="${1:-0}"
  local requested="${SAKURACORD_CODE_SIGN_IDENTITY:-}"
  local identities
  local status
  if [[ -z "$requested" ]]; then
    if requested="$(git config --global --get sakuracord.codeSignIdentity)"; then
      [[ -n "$requested" ]] || { echo "The saved signing identity is empty." >&2; return 2; }
    else
      status=$?
      [[ "$status" -eq 1 ]] || return "$status"
    fi
  fi
  identities=""
  if [[ "$requested" != "-" ]]; then
    identities="$(security find-identity -v -p codesigning 2>/dev/null)" || return
  fi
  if [[ -z "$requested" ]]; then
    requested="$(printf '%s\n' "$identities" | awk '/"SakuraCord Local Development"/ { print $2; exit }')"
    if [[ -z "$requested" ]]; then
      requested="$(printf '%s\n' "$identities" | awk '/"Apple Development: / { print $2; exit }')"
    fi
    if [[ -n "$requested" ]]; then
      git config --global sakuracord.codeSignIdentity "$requested" || return
    fi
  fi
  SAKURACORD_RESOLVED_CODE_SIGN_IDENTITY="-"
  if [[ -n "$requested" && "$requested" != "-" ]]; then
    SAKURACORD_RESOLVED_CODE_SIGN_IDENTITY="$(
      printf '%s\n' "$identities" | awk -v choice="$requested" \
        'toupper($2) == toupper(choice) || index($0, "\"" choice "\"") { print $2; exit }'
    )"
    if [[ -z "$SAKURACORD_RESOLVED_CODE_SIGN_IDENTITY" ]]; then
      echo "The configured code-signing identity is unavailable: $requested" >&2
      return 2
    fi
  fi
  if [[ "$required" == "1" && "$SAKURACORD_RESOLVED_CODE_SIGN_IDENTITY" == "-" ]]; then
    echo "Refusing to launch without a persistent signing identity. Run ./script/setup_local_signing_identity.sh." >&2
    return 2
  fi
}

sakuracord_verify_development_launch() {
  local metadata configuration updates_enabled credential_mode
  metadata="$(python3 - "$SAKURACORD_APP_BUNDLE/Contents/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as stream:
    info = plistlib.load(stream)
configuration = info.get("SakuraCordBuildConfiguration", "debug")
if configuration not in ("debug", "release"):
    sys.exit("Invalid SakuraCord build configuration.")
values = []
for key in ("SakuraCordUpdatesEnabled", "SakuraCordInsecureDebugCredentialsEnabled"):
    value = info.get(key, False)
    if type(value) is not bool:
        sys.exit(f"Invalid boolean in built app: {key}")
    values.append(int(value))
print(configuration, *values)
PY
  )" || return
  read -r configuration updates_enabled credential_mode <<<"$metadata"
  sakuracord_resolve_insecure_debug_credentials "$SAKURACORD_ROOT_DIR" || return
  if [[ "$configuration" == "release" ]]; then
    sakuracord_apply_secure_release_credential_policy run-release "$updates_enabled" || return
  else
    sakuracord_apply_secure_release_credential_policy run "$updates_enabled" || return
  fi
  # A release bundle packaged for distribution always uses Keychain. That is
  # stricter than the local preference, so it stays launchable.
  if [[ "$credential_mode" != "$SAKURACORD_RESOLVED_INSECURE_DEBUG_CREDENTIALS" ]] \
    && ! [[ "$configuration" == "release" && "$credential_mode" == "0" ]]; then
    echo "Refusing to launch: built credential mode is $credential_mode, expected $SAKURACORD_RESOLVED_INSECURE_DEBUG_CREDENTIALS ($SAKURACORD_INSECURE_DEBUG_CREDENTIALS_SOURCE). Rebuild with the current launcher and --build." >&2
    return 2
  fi
  sakuracord_resolve_code_sign_identity 1 || return
  codesign --verify --deep --strict \
    "-R=identifier \"$SAKURACORD_BUNDLE_ID\" and certificate leaf = H\"$SAKURACORD_RESOLVED_CODE_SIGN_IDENTITY\"" \
    "$SAKURACORD_APP_BUNDLE" || {
      echo "Refusing to launch: the app must have a valid signature from the configured development identity." >&2
      return 2
    }
  echo "Launch verified: credential mode $credential_mode; signing identity $SAKURACORD_RESOLVED_CODE_SIGN_IDENTITY"
}
