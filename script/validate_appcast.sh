#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=release_metadata.sh
source "$ROOT_DIR/script/release_metadata.sh"
RELEASE_VERSION="$(sakuracord_release_version "$ROOT_DIR")"
EXPECTED_TAG="${SAKURACORD_RELEASE_TAG:-${GITHUB_REF_NAME:-}}"
if [[ -n "$EXPECTED_TAG" ]]; then
  DMG_NAME="$(sakuracord_release_dmg_name_from_tag "$EXPECTED_TAG")"
else
  DMG_NAME="$(sakuracord_release_dmg_name "$RELEASE_VERSION")"
fi
APPCAST_PATH="${1:-$ROOT_DIR/dist/appcast.xml}"
DMG_PATH="${2:-$ROOT_DIR/dist/$DMG_NAME}"

if [[ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  echo "SPARKLE_ED_PRIVATE_KEY is required to verify Sparkle signatures." >&2
  exit 2
fi
if [[ -z "${SPARKLE_ED_PUBLIC_KEY:-}" ]]; then
  echo "SPARKLE_ED_PUBLIC_KEY is required to verify the bundled trust metadata." >&2
  exit 2
fi
if ! DERIVED_PUBLIC_KEY="$(
  swift -e '
    import CryptoKit
    import Foundation

    guard
        let encodedSeed = ProcessInfo.processInfo.environment["SPARKLE_ED_PRIVATE_KEY"],
        let seed = Data(base64Encoded: encodedSeed)
    else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    print(privateKey.publicKey.rawRepresentation.base64EncodedString())
  ' 2>/dev/null
)"; then
  echo "SPARKLE_ED_PRIVATE_KEY is not a valid base64-encoded Ed25519 seed." >&2
  exit 2
fi
if [[ "$DERIVED_PUBLIC_KEY" != "$SPARKLE_ED_PUBLIC_KEY" ]]; then
  echo "SPARKLE_ED_PRIVATE_KEY and SPARKLE_ED_PUBLIC_KEY are not a keypair." >&2
  exit 2
fi
if [[ ! -f "$APPCAST_PATH" || ! -f "$DMG_PATH" ]]; then
  echo "Both an appcast and DMG are required for validation." >&2
  exit 2
fi

SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-}"
if [[ -z "$SIGN_UPDATE" || ! -x "$SIGN_UPDATE" ]]; then
  echo "SPARKLE_SIGN_UPDATE must point to Sparkle's executable sign_update tool." >&2
  exit 2
fi

xmllint --noout "$APPCAST_PATH"
ENCLOSURE_SIGNATURE="$(
  xmllint --xpath \
    'string((//*[local-name()="enclosure"])[1]/@*[local-name()="edSignature"])' \
    "$APPCAST_PATH"
)"
ENCLOSURE_URL="$(
  xmllint --xpath 'string((//*[local-name()="enclosure"])[1]/@url)' "$APPCAST_PATH"
)"
APPCAST_VERSION="$(
  xmllint --xpath \
    'string((//*[local-name()="item"])[1]/*[local-name()="version"])' \
    "$APPCAST_PATH"
)"
APPCAST_SHORT_VERSION="$(
  xmllint --xpath \
    'string((//*[local-name()="item"])[1]/*[local-name()="shortVersionString"])' \
    "$APPCAST_PATH"
)"
APPCAST_HAS_RELEASE_NOTES="$(
  xmllint --xpath \
    'boolean(normalize-space(string((//*[local-name()="item"])[1]/*[local-name()="description"])))' \
    "$APPCAST_PATH"
)"
APPCAST_FULL_RELEASE_NOTES_URL="$(
  xmllint --xpath \
    'string((//*[local-name()="item"])[1]/*[local-name()="fullReleaseNotesLink"])' \
    "$APPCAST_PATH"
)"
ENCLOSURE_LENGTH="$(
  xmllint --xpath 'string((//*[local-name()="enclosure"])[1]/@length)' "$APPCAST_PATH"
)"

if [[ -z "$ENCLOSURE_SIGNATURE" ]]; then
  echo "The appcast enclosure is missing its Sparkle EdDSA signature." >&2
  exit 1
fi
if [[ -z "$EXPECTED_TAG" || -z "${SAKURACORD_BUILD_NUMBER:-}" || -z "${SAKURACORD_VERSION:-}" ]]; then
  echo "Release tag, build number, and version are required for appcast validation." >&2
  exit 2
fi
EXPECTED_DMG_URL_NAME="$(sakuracord_release_dmg_name_from_tag "$EXPECTED_TAG")"
if [[ "$(basename "$DMG_PATH")" != "$EXPECTED_DMG_URL_NAME" ]]; then
  echo "Unexpected release archive name: $(basename "$DMG_PATH")" >&2
  exit 1
fi
EXPECTED_URL="https://github.com/SakuraCordApp/SakuraCord/releases/download/$EXPECTED_TAG/$EXPECTED_DMG_URL_NAME"
if [[ "$ENCLOSURE_URL" != "$EXPECTED_URL" ]]; then
  echo "Unexpected appcast enclosure URL: $ENCLOSURE_URL" >&2
  exit 1
fi
if [[ "$APPCAST_VERSION" != "${SAKURACORD_BUILD_NUMBER:-}" ]]; then
  echo "Appcast build version does not match SAKURACORD_BUILD_NUMBER." >&2
  exit 1
fi
EXPECTED_APPCAST_DISPLAY_VERSION="$(
  sakuracord_release_appcast_display_version_from_tag "$EXPECTED_TAG"
)"
if [[ "$APPCAST_SHORT_VERSION" != "$EXPECTED_APPCAST_DISPLAY_VERSION" ]]; then
  echo "Appcast short version does not match the release display version." >&2
  exit 1
fi
if [[ "$APPCAST_HAS_RELEASE_NOTES" != "true" ]]; then
  echo "The appcast does not contain embedded release notes." >&2
  exit 1
fi
EXPECTED_RELEASE_URL="https://github.com/SakuraCordApp/SakuraCord/releases/tag/$EXPECTED_TAG"
if [[ "$APPCAST_FULL_RELEASE_NOTES_URL" != "$EXPECTED_RELEASE_URL" ]]; then
  echo "Unexpected full release notes URL: $APPCAST_FULL_RELEASE_NOTES_URL" >&2
  exit 1
fi
DMG_LENGTH="$(stat -f '%z' "$DMG_PATH")"
if [[ "$ENCLOSURE_LENGTH" != "$DMG_LENGTH" ]]; then
  echo "Appcast enclosure length does not match the release DMG." >&2
  exit 1
fi

printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | \
  "$SIGN_UPDATE" --verify --ed-key-file - "$APPCAST_PATH"
printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | \
  "$SIGN_UPDATE" --verify --ed-key-file - "$DMG_PATH" "$ENCLOSURE_SIGNATURE"

ATTACH_OUTPUT="$(hdiutil attach -readonly -nobrowse "$DMG_PATH")"
MOUNT_POINT="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '/\/Volumes\// { print $NF; exit }')"
if [[ -z "$MOUNT_POINT" ]]; then
  echo "Could not determine the mounted DMG path." >&2
  exit 1
fi
cleanup() {
  hdiutil detach "$MOUNT_POINT" >/dev/null
}
trap cleanup EXIT

APP_BUNDLE="$MOUNT_POINT/SakuraCord.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "The release DMG does not contain SakuraCord.app." >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

assert_plist_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(plutil -extract "$key" raw -o - "$INFO_PLIST")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Unexpected $key in the packaged app." >&2
    exit 1
  fi
}

assert_plist_value "CFBundleIdentifier" "dev.sakuracord.SakuraCord"
assert_plist_value "CFBundleVersion" "$SAKURACORD_BUILD_NUMBER"
assert_plist_value "CFBundleShortVersionString" "$SAKURACORD_VERSION"
assert_plist_value "SakuraCordReleaseDisplayVersion" \
  "$EXPECTED_APPCAST_DISPLAY_VERSION"
assert_plist_value "SakuraCordUpdatesEnabled" "true"
EXPECTED_RELEASE_TRACK="$(sakuracord_release_track_from_tag "$EXPECTED_TAG")"
assert_plist_value "SakuraCordReleaseTrack" "$EXPECTED_RELEASE_TRACK"
if [[ "$EXPECTED_RELEASE_TRACK" == "nightly" ]]; then
  assert_plist_value "SUAllowsVersionDowngrades" "true"
elif plutil -extract "SUAllowsVersionDowngrades" raw -o - "$INFO_PLIST" \
  >/dev/null 2>&1; then
  echo "Regular builds must keep Sparkle downgrade protection enabled." >&2
  exit 1
fi
assert_plist_value "SUFeedURL" \
  "https://github.com/SakuraCordApp/SakuraCord/releases/latest/download/appcast.xml"
assert_plist_value "SakuraCordNightlyFeedURL" \
  "https://raw.githubusercontent.com/SakuraCordApp/SakuraCord/nightly-feed/appcast.xml"
assert_plist_value "SUPublicEDKey" "$SPARKLE_ED_PUBLIC_KEY"
assert_plist_value "SUEnableAutomaticChecks" "true"
assert_plist_value "SUScheduledCheckInterval" "21600"
assert_plist_value "SUAutomaticallyUpdate" "false"
assert_plist_value "SUAllowsAutomaticUpdates" "true"
assert_plist_value "SUEnableInstallerLauncherService" "true"
assert_plist_value "SUVerifyUpdateBeforeExtraction" "true"
assert_plist_value "SURequireSignedFeed" "true"

if [[ ! -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then
  echo "The packaged app is missing Sparkle.framework." >&2
  exit 1
fi
THIRD_PARTY_NOTICES="$APP_BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md"
if [[ ! -f "$THIRD_PARTY_NOTICES" ]] \
  || ! grep -Fq "## Sparkle" "$THIRD_PARTY_NOTICES" \
  || ! grep -Fq "Copyright (c) 2006-2013 Andy Matuschak." "$THIRD_PARTY_NOTICES" \
  || ! grep -Fq "## Zstandard" "$THIRD_PARTY_NOTICES" \
  || ! grep -Fq "Copyright (c) Meta Platforms, Inc. and affiliates." \
    "$THIRD_PARTY_NOTICES"; then
  echo "The packaged app is missing required third-party notices." >&2
  exit 1
fi

ENTITLEMENTS="$(
  codesign -d --entitlements :- "$APP_BUNDLE" 2>/dev/null
)"
for service in \
  "dev.sakuracord.SakuraCord-spks" \
  "dev.sakuracord.SakuraCord-spki"; do
  if [[ "$ENTITLEMENTS" != *"$service"* ]]; then
    echo "The packaged app is missing the Sparkle Mach service entitlement: $service" >&2
    exit 1
  fi
done

printf 'Validated Sparkle appcast, archive signature, bundle metadata, entitlements, and nested code signatures.\n'
