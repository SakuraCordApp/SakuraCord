#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
SIMULATOR_SCENARIO=""
if [[ "$MODE" == --simulator=* ]]; then
  SIMULATOR_SCENARIO="${MODE#--simulator=}"
  MODE=--simulator
fi
# Each benchmark runs signed in to the local Discord simulator on the
# scenario it measures: the scenario, its parameters and the app's flags.
BENCHMARK_SIMULATOR_ARGS=()
BENCHMARK_APP_ARGS=("$MODE")
case "$MODE" in
  --benchmark-chat-autoscroll|--benchmark-chat-live-autoscroll)
    BENCHMARK_SIMULATOR_ARGS=(--scenario chat-performance --param messages=5000 --param content=text) ;;
  --benchmark-chat-media-autoscroll|--benchmark-chat-voice-autoscroll|--benchmark-chat-files-autoscroll)
    CONTENT="${MODE#--benchmark-chat-}"
    BENCHMARK_SIMULATOR_ARGS=(--scenario chat-performance --param messages=5000 --param "content=${CONTENT%-autoscroll}")
    BENCHMARK_APP_ARGS=(--benchmark-chat-autoscroll) ;;
  # The reaction storms are the live timeline benchmark carrying only
  # reaction traffic, scrolling or still.
  --benchmark-chat-reaction-storm-autoscroll|--benchmark-chat-reaction-storm-idle)
    BENCHMARK_SIMULATOR_ARGS=(--scenario chat-performance --param messages=5000 --param content=text)
    BENCHMARK_APP_ARGS=(--benchmark-chat-live-autoscroll --benchmark-chat-live-reactions-only)
    [[ "$MODE" == *-idle ]] && BENCHMARK_APP_ARGS+=(--benchmark-chat-idle) ;;
  --benchmark-channel-open)
    BENCHMARK_SIMULATOR_ARGS=(--scenario chat-performance --param messages=5000 --param content=files) ;;
  --benchmark-pins-autoscroll)
    BENCHMARK_SIMULATOR_ARGS=(--scenario chat-performance --param messages=5000 --param pins=5000) ;;
  --benchmark-forum-autoscroll|--benchmark-forum-gallery-resize)
    BENCHMARK_SIMULATOR_ARGS=(--scenario forum-performance --param posts=5000) ;;
  --benchmark-friends) BENCHMARK_SIMULATOR_ARGS=(--scenario friends-performance) ;;
  --benchmark-server-rail) BENCHMARK_SIMULATOR_ARGS=(--scenario server-rail) ;;
  --benchmark-unread-churn) BENCHMARK_SIMULATOR_ARGS=(--scenario long-server-list) ;;
esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=runtime.sh
source "$ROOT_DIR/script/runtime.sh"
# shellcheck source=release_metadata.sh
source "$ROOT_DIR/script/release_metadata.sh"
# shellcheck source=debug_credentials_config.sh
source "$ROOT_DIR/script/debug_credentials_config.sh"

MODES=(
  package
  package-release
  run
  run-release
  --simulator
  --simulator-sign-in
  --benchmark-chat-autoscroll
  --benchmark-chat-live-autoscroll
  --benchmark-chat-reaction-storm-autoscroll
  --benchmark-chat-reaction-storm-idle
  --benchmark-chat-media-autoscroll
  --benchmark-chat-voice-autoscroll
  --benchmark-chat-files-autoscroll
  --benchmark-channel-open
  --benchmark-pins-autoscroll
  --benchmark-forum-autoscroll
  --benchmark-forum-gallery-resize
  --benchmark-friends
  --benchmark-server-rail
  --benchmark-unread-churn
  --media-viewer-benchmark
  --verify
  --debug
  --logs
  --telemetry
)
IS_KNOWN_MODE=0
for KNOWN_MODE in "${MODES[@]}"; do
  if [[ "$KNOWN_MODE" == "$MODE" ]]; then IS_KNOWN_MODE=1; fi
done
if [[ "$IS_KNOWN_MODE" != "1" ]]; then
  echo "usage: $0 [$(IFS='|'; echo "${MODES[*]}")]" >&2
  exit 2
fi

BUNDLE_ID="$SAKURACORD_BUNDLE_ID"
PACKAGE_DIR="$SAKURACORD_PACKAGE_DIR"
DIST_DIR="$SAKURACORD_DIST_DIR"
PRODUCT_NAME="$SAKURACORD_PRODUCT_NAME"
BUNDLE_SHORT_VERSION="$(sakuracord_release_version "$ROOT_DIR")"
BUNDLE_DISPLAY_VERSION="$(
  sakuracord_bundle_display_version "$ROOT_DIR" "$BUNDLE_SHORT_VERSION"
)"
BUNDLE_BUILD_VERSION="${SAKURACORD_BUILD_NUMBER:-1}"
if [[ ! "$BUNDLE_BUILD_VERSION" =~ ^[0-9]+$ ]]; then
  echo "SAKURACORD_BUILD_NUMBER must be an integer." >&2
  exit 2
fi
UPDATES_ENABLED="${SAKURACORD_ENABLE_UPDATES:-0}"
if [[ "$UPDATES_ENABLED" != "0" && "$UPDATES_ENABLED" != "1" ]]; then
  echo "SAKURACORD_ENABLE_UPDATES must be 0 or 1." >&2
  exit 2
fi
RELEASE_TRACK="${SAKURACORD_RELEASE_TRACK:-regular}"
if [[ "$RELEASE_TRACK" != "regular" && "$RELEASE_TRACK" != "nightly" ]]; then
  echo "SAKURACORD_RELEASE_TRACK must be regular or nightly." >&2
  exit 2
fi
sakuracord_resolve_insecure_debug_credentials "$ROOT_DIR"
sakuracord_apply_secure_release_credential_policy "$MODE" "$UPDATES_ENABLED"
INSECURE_DEBUG_CREDENTIALS="$SAKURACORD_RESOLVED_INSECURE_DEBUG_CREDENTIALS"
INSECURE_DEBUG_CREDENTIALS_SOURCE="$SAKURACORD_INSECURE_DEBUG_CREDENTIALS_SOURCE"
if [[ "$UPDATES_ENABLED" == "1" ]]; then
  if [[ -z "${SPARKLE_ED_PUBLIC_KEY:-}" ]]; then
    echo "SPARKLE_ED_PUBLIC_KEY is required when production updates are enabled." >&2
    exit 2
  fi
  if ! public_key_bytes="$(
    printf '%s' "$SPARKLE_ED_PUBLIC_KEY" \
      | base64 -D 2>/dev/null \
      | wc -c \
      | tr -d '[:space:]'
  )"; then
    echo "SPARKLE_ED_PUBLIC_KEY is not valid base64." >&2
    exit 2
  fi
  if [[ "$public_key_bytes" != "32" ]]; then
    echo "SPARKLE_ED_PUBLIC_KEY must be a base64-encoded 32-byte Ed25519 public key." >&2
    exit 2
  fi
fi
BUILD_FLAGS=()
BUILD_CONFIGURATION=debug
if [[ "$MODE" == "package-release" || "$MODE" == "run-release" ]]; then
  BUILD_CONFIGURATION=release
  BUILD_FLAGS=(-c release --disable-index-store)
fi
sakuracord_select_app_variant "$BUILD_CONFIGURATION" "$RELEASE_TRACK"
APP_NAME="$SAKURACORD_APP_NAME"
DISPLAY_NAME="$SAKURACORD_DISPLAY_NAME"
APP_BUNDLE="$SAKURACORD_APP_BUNDLE"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
FRAMEWORKS="$CONTENTS/Frameworks"
RESOURCES="$CONTENTS/Resources"
# Each variant compiles its own Icon Composer document under the shared
# asset name, so the app keeps native icon appearances.
APP_ICON_NAME="$SAKURACORD_PRODUCT_NAME"
APP_ICON_SOURCE="${SAKURACORD_APP_ICON:-$SAKURACORD_APP_ICON_SOURCE}"
if [[ "$APP_ICON_SOURCE" = /* ]]; then
  APP_ICON="$APP_ICON_SOURCE"
else
  APP_ICON="$ROOT_DIR/App/Packaging/$APP_ICON_SOURCE"
fi
if [[ "$MODE" == "package" || "$MODE" == "package-release" ]]; then
  sakuracord_resolve_code_sign_identity 0
else
  sakuracord_resolve_code_sign_identity 1
fi
CODE_SIGN_IDENTITY="$SAKURACORD_RESOLVED_CODE_SIGN_IDENTITY"

sakuracord_acquire_operation_lock
ICON_STAGING_DIR=""
ENTITLEMENTS_STAGING=""
cleanup() {
  if [[ -n "$ICON_STAGING_DIR" && -d "$ICON_STAGING_DIR" ]]; then
    rm -rf "$ICON_STAGING_DIR"
  fi
  if [[ -n "$ENTITLEMENTS_STAGING" && -f "$ENTITLEMENTS_STAGING" ]]; then
    rm -f "$ENTITLEMENTS_STAGING"
  fi
  sakuracord_release_operation_lock
}
trap cleanup EXIT

sakuracord_print_identity
if [[ "$INSECURE_DEBUG_CREDENTIALS" == "1" ]]; then
  echo "Debug credentials: enabled ($INSECURE_DEBUG_CREDENTIALS_SOURCE)"
else
  echo "Debug credentials: disabled ($INSECURE_DEBUG_CREDENTIALS_SOURCE)"
fi
if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
  echo "Code signing: ad-hoc (Screen Recording permission will not persist across builds)"
else
  echo "Code signing: $CODE_SIGN_IDENTITY"
fi

if [[ "$MODE" != "package" && "$MODE" != "package-release" ]]; then
  sakuracord_stop_scoped_app
fi

swift build \
  --package-path "$PACKAGE_DIR" \
  --cache-path "$SAKURACORD_SWIFTPM_CACHE_DIR" \
  --scratch-path "$SAKURACORD_SCRATCH_DIR" \
  ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} \
  --product "$PRODUCT_NAME"
BIN_DIR="$(swift build \
  --package-path "$PACKAGE_DIR" \
  --cache-path "$SAKURACORD_SWIFTPM_CACHE_DIR" \
  --scratch-path "$SAKURACORD_SCRATCH_DIR" \
  ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} \
  --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$FRAMEWORKS" "$RESOURCES"
cp "$BIN_DIR/$PRODUCT_NAME" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"
# macOS named-sound lookup finds AIFF resources but skips CAF resources.
/usr/bin/afconvert -f AIFF -d BEI16 \
  "$PACKAGE_DIR/Sources/SakuraCord/Resources/Sounds/message1.mp3" \
  "$RESOURCES/message1.aiff"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/$APP_NAME"
for resource_bundle in "$BIN_DIR"/*.bundle; do
  [[ -d "$resource_bundle" ]] || continue
  ditto "$resource_bundle" "$RESOURCES/$(basename "$resource_bundle")"
done
for framework in "$BIN_DIR"/*.framework; do
  [[ -d "$framework" ]] || continue
  framework_name="$(basename "$framework")"
  ditto "$framework" "$FRAMEWORKS/$framework_name"
  codesign --force --sign "$CODE_SIGN_IDENTITY" "$FRAMEWORKS/$framework_name" >/dev/null
done
cp "$ROOT_DIR/docs/THIRD_PARTY_NOTICES.md" "$RESOURCES/THIRD_PARTY_NOTICES.md"
if ! grep -Fq "## Zstandard" "$RESOURCES/THIRD_PARTY_NOTICES.md" \
  || ! grep -Fq "Copyright (c) Meta Platforms, Inc. and affiliates." \
    "$RESOURCES/THIRD_PARTY_NOTICES.md" \
  || ! grep -Fq "## SocialSymbols" "$RESOURCES/THIRD_PARTY_NOTICES.md" \
  || ! grep -Fq "Apache License" "$RESOURCES/THIRD_PARTY_NOTICES.md"; then
  echo "packaged third-party notices are missing a required license" >&2
  exit 1
fi
ditto "$ROOT_DIR/Releases" "$RESOURCES/Releases"

if [[ ! -d "$APP_ICON" ]]; then
  echo "missing app icon: $APP_ICON" >&2
  exit 1
fi
ICON_STAGING_DIR="$(mktemp -d "$DIST_DIR/SakuraCordIconSource.XXXXXX")"
ditto "$APP_ICON" "$ICON_STAGING_DIR/$APP_ICON_NAME.icon"
ICON_PARTIAL_PLIST="$DIST_DIR/SakuraCordIcon-Info.plist"
xcrun actool \
  --compile "$RESOURCES" \
  --platform macosx \
  --minimum-deployment-target 27.0 \
  --app-icon "$APP_ICON_NAME" \
  --accent-color AccentColor \
  --output-partial-info-plist "$ICON_PARTIAL_PLIST" \
  --warnings --notices --errors \
  "$ICON_STAGING_DIR/$APP_ICON_NAME.icon" \
  "$ROOT_DIR/App/Packaging/SettingsDocument.xcassets" \
  "$ROOT_DIR/App/Packaging/Appearance.xcassets"
rm -f "$ICON_PARTIAL_PLIST"

cat >"$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>SakuraCordBuildConfiguration</key><string>$BUILD_CONFIGURATION</string>
  <key>SakuraCordBuildSwitchingProtocol</key><integer>1</integer>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleIconFile</key><string>$APP_ICON_NAME</string>
  <key>CFBundleIconName</key><string>$APP_ICON_NAME</string>
  <key>NSAccentColorName</key><string>AccentColor</string>
  <key>UTExportedTypeDeclarations</key>
  <array><dict>
    <key>UTTypeIdentifier</key><string>dev.sakuracord.settings</string>
    <key>UTTypeDescription</key><string>SakuraCord Settings</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.content</string></array>
    <key>UTTypeTagSpecification</key><dict>
      <key>public.filename-extension</key><array><string>sakurasettings</string></array>
    </dict>
    <key>UTTypeIcons</key><dict>
      <key>UTTypeIconBackgroundName</key><string>SettingsDocumentBackground</string>
      <key>UTTypeIconBadgeName</key><string>SettingsDocumentFlower</string>
      <key>UTTypeIconText</key><string>Settings</string>
    </dict>
  </dict></array>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>SakuraCord Settings</string>
    <key>CFBundleTypeRole</key><string>None</string>
    <key>LSItemContentTypes</key><array><string>dev.sakuracord.settings</string></array>
  </dict></array>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$BUNDLE_SHORT_VERSION</string>
  <key>SakuraCordReleaseDisplayVersion</key><string>$BUNDLE_DISPLAY_VERSION</string>
  <key>CFBundleVersion</key><string>$BUNDLE_BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>SakuraCord uses your microphone when you join a voice call or record a voice message.</string>
  <key>NSCameraUsageDescription</key><string>SakuraCord uses your camera when you enable video in a call.</string>
  <key>NSScreenCaptureUsageDescription</key><string>SakuraCord uses screen capture only when you choose a source to share in a voice call.</string>
</dict>
</plist>
PLIST

if [[ "$UPDATES_ENABLED" == "1" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SakuraCordUpdatesEnabled bool true" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c \
    "Add :SakuraCordReleaseTrack string $RELEASE_TRACK" \
    "$CONTENTS/Info.plist"
  if [[ "$RELEASE_TRACK" == "nightly" ]]; then
    /usr/libexec/PlistBuddy -c \
      "Add :SUAllowsVersionDowngrades bool true" \
      "$CONTENTS/Info.plist"
  fi
  /usr/libexec/PlistBuddy -c \
    "Add :SUFeedURL string https://github.com/SakuraCordApp/SakuraCord/releases/latest/download/appcast.xml" \
    "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c \
    "Add :SakuraCordNightlyFeedURL string https://sakuracord.app/updates/appcast.xml" \
    "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_ED_PUBLIC_KEY" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUScheduledCheckInterval integer 21600" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUAutomaticallyUpdate bool false" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUAllowsAutomaticUpdates bool true" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUEnableInstallerLauncherService bool true" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUVerifyUpdateBeforeExtraction bool true" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SURequireSignedFeed bool true" "$CONTENTS/Info.plist"
fi
if [[ "${SAKURACORD_PR_BUILD:-0}" == "1" ]]; then
  python3 "$ROOT_DIR/script/pr_build_archive.py" embed "$APP_BUNDLE"
fi
if [[ "$INSECURE_DEBUG_CREDENTIALS" == "1" ]]; then
  /usr/libexec/PlistBuddy -c \
    "Add :SakuraCordInsecureDebugCredentialsEnabled bool true" \
    "$CONTENTS/Info.plist"
fi
plutil -lint "$CONTENTS/Info.plist" >/dev/null

ENTITLEMENTS_STAGING="$(mktemp "$DIST_DIR/SakuraCord.entitlements.XXXXXX")"
sed "s/__SAKURACORD_BUNDLE_IDENTIFIER__/$BUNDLE_ID/g" \
  "$ROOT_DIR/Config/SakuraCord.entitlements" >"$ENTITLEMENTS_STAGING"
if [[ "$UPDATES_ENABLED" != "1" ]]; then
  /usr/libexec/PlistBuddy -c \
    "Delete :com.apple.security.temporary-exception.mach-lookup.global-name" \
    "$ENTITLEMENTS_STAGING"
fi
plutil -lint "$ENTITLEMENTS_STAGING" >/dev/null
codesign --force --sign "$CODE_SIGN_IDENTITY" \
  --entitlements "$ENTITLEMENTS_STAGING" "$APP_BUNDLE" >/dev/null
if [[ "$BUILD_CONFIGURATION" == release ]]; then
  "$ROOT_DIR/script/check_release_redirect.sh" "$APP_BUNDLE"
fi

# Starts the Discord simulator with the options before `--` and launches the
# packaged debug app connected to it, signed in to the scenario's account
# unless SIGNS_IN=0, with the app arguments after `--`.
launch_on_simulator() {
  local simulator_arguments=() launch_arguments=()
  while [[ $# -gt 0 && "$1" != -- ]]; do simulator_arguments+=("$1"); shift; done
  [[ $# -gt 0 ]] && shift
  "$ROOT_DIR/script/simulator.sh" start "${simulator_arguments[@]}"
  if [[ "${SIGNS_IN:-1}" == 1 ]]; then
    launch_arguments+=(--env "SAKURACORD_SIMULATOR_TOKEN=$("$ROOT_DIR/script/simulator.sh" token)")
  fi
  # Forward the result path, which `open` does not pass on by itself.
  if [[ -n "${SAKURACORD_PERFORMANCE_RESULT_PATH:-}" ]]; then
    launch_arguments+=(--env "SAKURACORD_PERFORMANCE_RESULT_PATH=$SAKURACORD_PERFORMANCE_RESULT_PATH")
  fi
  sakuracord_launch_scoped_app ${launch_arguments[@]+"${launch_arguments[@]}"} \
    --args --discord-simulator "${SAKURACORD_DISCORD_SIMULATOR_PORT:-47100}" "$@"
}

case "$MODE" in
  package|package-release) ;;
  run|run-release) sakuracord_launch_scoped_app ;;
  --debug)
    sakuracord_verify_development_launch
    sakuracord_stop_scoped_app
    sakuracord_record_simulator_launch "$APP_BUNDLE"
    lldb -- "$MACOS/$APP_NAME"
    ;;
  --logs)
    sakuracord_launch_scoped_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry)
    sakuracord_launch_scoped_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify)
    # Verification must never touch a stored Discord credential or the live
    # API: the simulator launch keeps its own accounts.
    launch_on_simulator --scenario demo
    sleep 2
    sakuracord_is_scoped_app_running
    ;;
  --simulator) launch_on_simulator --scenario "${SIMULATOR_SCENARIO:-demo}" ;;
  --simulator-sign-in)
    sakuracord_reset_simulator_account
    SIGNS_IN=0 launch_on_simulator --scenario demo
    ;;
  # A fixed delay, so runs compare, whichever scenario the benchmark uses.
  --benchmark-*) launch_on_simulator --network standard "${BENCHMARK_SIMULATOR_ARGS[@]}" -- "${BENCHMARK_APP_ARGS[@]}" ;;
  --media-viewer-benchmark) sakuracord_launch_scoped_app --env SAKURACORD_MEDIA_VIEWER_BENCHMARK=1 ;;
esac
