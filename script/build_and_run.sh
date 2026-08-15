#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=runtime.sh
source "$ROOT_DIR/script/runtime.sh"
# shellcheck source=release_metadata.sh
source "$ROOT_DIR/script/release_metadata.sh"
# shellcheck source=debug_credentials_config.sh
source "$ROOT_DIR/script/debug_credentials_config.sh"

case "$MODE" in
  package|package-release|run|--offline|--offline-long-server-list|--offline-forum-performance|--offline-chat-performance|--offline-chat-performance-autoscroll|--offline-chat-performance-live-autoscroll|--offline-chat-media-performance-autoscroll|--offline-incoming-private-call|--verify|--debug|--logs|--telemetry) ;;
  *)
    echo "usage: $0 [package|package-release|run|--offline|--offline-long-server-list|--offline-forum-performance|--offline-chat-performance|--offline-chat-performance-autoscroll|--offline-chat-performance-live-autoscroll|--offline-chat-media-performance-autoscroll|--offline-incoming-private-call|--verify|--debug|--logs|--telemetry]" >&2
    exit 2
    ;;
esac

APP_NAME="$SAKURACORD_APP_NAME"
DISPLAY_NAME="$SAKURACORD_DISPLAY_NAME"
BUNDLE_ID="$SAKURACORD_BUNDLE_ID"
PACKAGE_DIR="$SAKURACORD_PACKAGE_DIR"
DIST_DIR="$SAKURACORD_DIST_DIR"
APP_BUNDLE="$SAKURACORD_APP_BUNDLE"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
FRAMEWORKS="$CONTENTS/Frameworks"
RESOURCES="$CONTENTS/Resources"
PRODUCT_NAME="$SAKURACORD_PRODUCT_NAME"
BUNDLE_SHORT_VERSION="$(sakuracord_release_version "$ROOT_DIR")"
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
if [[ "$MODE" == "package-release" ]]; then
  BUILD_FLAGS=(-c release --disable-index-store)
fi
APP_ICON_NAME="$SAKURACORD_PRODUCT_NAME"
APP_ICON_SOURCE="${SAKURACORD_APP_ICON:-SakuraCord.icon}"
if [[ "$APP_ICON_SOURCE" = /* ]]; then
  APP_ICON="$APP_ICON_SOURCE"
else
  APP_ICON="$ROOT_DIR/App/Packaging/$APP_ICON_SOURCE"
fi

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
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/$APP_NAME"
for resource_bundle in "$BIN_DIR"/*.bundle; do
  [[ -d "$resource_bundle" ]] || continue
  ditto "$resource_bundle" "$RESOURCES/$(basename "$resource_bundle")"
done
for framework in "$BIN_DIR"/*.framework; do
  [[ -d "$framework" ]] || continue
  framework_name="$(basename "$framework")"
  ditto "$framework" "$FRAMEWORKS/$framework_name"
  codesign --force --sign - "$FRAMEWORKS/$framework_name" >/dev/null
done
cp "$ROOT_DIR/docs/THIRD_PARTY_NOTICES.md" "$RESOURCES/THIRD_PARTY_NOTICES.md"
if ! grep -Fq "## Zstandard" "$RESOURCES/THIRD_PARTY_NOTICES.md" \
  || ! grep -Fq "Copyright (c) Meta Platforms, Inc. and affiliates." \
    "$RESOURCES/THIRD_PARTY_NOTICES.md"; then
  echo "packaged third-party notices are missing the Zstandard license" >&2
  exit 1
fi

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
  --output-partial-info-plist "$ICON_PARTIAL_PLIST" \
  --warnings --notices --errors \
  "$ICON_STAGING_DIR/$APP_ICON_NAME.icon"
rm -f "$ICON_PARTIAL_PLIST"

cat >"$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleIconFile</key><string>$APP_ICON_NAME</string>
  <key>CFBundleIconName</key><string>$APP_ICON_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$BUNDLE_SHORT_VERSION</string>
  <key>CFBundleVersion</key><string>$BUNDLE_BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>SakuraCord uses your microphone when you join a voice call.</string>
  <key>NSCameraUsageDescription</key><string>SakuraCord uses your camera when you enable video in a call.</string>
</dict>
</plist>
PLIST

if [[ "$UPDATES_ENABLED" == "1" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SakuraCordUpdatesEnabled bool true" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c \
    "Add :SUFeedURL string https://github.com/SakuraCordApp/SakuraCord/releases/latest/download/appcast.xml" \
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
codesign --force --sign - --entitlements "$ENTITLEMENTS_STAGING" "$APP_BUNDLE" >/dev/null

open_app() {
  /usr/bin/open -n "$APP_BUNDLE" "$@"
  sakuracord_wait_for_scoped_app
}
open_offline_app() { open_app --args --offline; }
open_offline_long_server_list() { open_app --args --offline-long-server-list; }
open_offline_forum_performance() { open_app --args --offline-forum-performance; }
open_offline_chat_performance() { open_app --args --offline-chat-performance; }
open_offline_chat_performance_autoscroll() {
  open_app --args --offline-chat-performance-autoscroll
}
open_offline_chat_performance_live_autoscroll() {
  open_app --args --offline-chat-performance-live-autoscroll
}
open_offline_chat_media_performance_autoscroll() {
  open_app --args --offline-chat-media-performance-autoscroll
}
open_offline_incoming_private_call() {
  open_app --args --offline-incoming-private-call
}

case "$MODE" in
  package|package-release) ;;
  run) open_app ;;
  --debug) lldb -- "$MACOS/$APP_NAME" ;;
  --logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify)
    # Verification must never touch a stored Discord credential or the live API.
    open_offline_app
    sleep 2
    sakuracord_is_scoped_app_running
    ;;
  --offline) open_offline_app ;;
  --offline-long-server-list) open_offline_long_server_list ;;
  --offline-forum-performance) open_offline_forum_performance ;;
  --offline-chat-performance) open_offline_chat_performance ;;
  --offline-chat-performance-autoscroll) open_offline_chat_performance_autoscroll ;;
  --offline-chat-performance-live-autoscroll) open_offline_chat_performance_live_autoscroll ;;
  --offline-chat-media-performance-autoscroll) open_offline_chat_media_performance_autoscroll ;;
  --offline-incoming-private-call) open_offline_incoming_private_call ;;
esac
