#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=worktree_runtime.sh
source "$ROOT_DIR/script/worktree_runtime.sh"

case "$MODE" in
  package|package-release|--offline|--offline-long-server-list|--offline-forum-performance|--verify) ;;
  run|--debug|--logs|--telemetry)
    if [[ "$SAKURACORD_IS_MAIN_WORKTREE" -ne 1 && "${SAKURACORD_ALLOW_LIVE_WORKTREE:-0}" != "1" ]]; then
      echo "Live-account launch is disabled in linked worktrees. Use --offline, or set SAKURACORD_ALLOW_LIVE_WORKTREE=1 deliberately." >&2
      exit 2
    fi
    ;;
  *)
    echo "usage: $0 [package|package-release|run|--offline|--offline-long-server-list|--offline-forum-performance|--verify|--debug|--logs|--telemetry]" >&2
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
BUNDLE_SHORT_VERSION="${SAKURACORD_VERSION:-0.1.0}"
BUNDLE_BUILD_VERSION="${SAKURACORD_BUILD_NUMBER:-1}"
if [[ ! "$BUNDLE_SHORT_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "SAKURACORD_VERSION must contain one to three dot-separated integers." >&2
  exit 2
fi
if [[ ! "$BUNDLE_BUILD_VERSION" =~ ^[0-9]+$ ]]; then
  echo "SAKURACORD_BUILD_NUMBER must be an integer." >&2
  exit 2
fi
BUILD_FLAGS=()
if [[ "$MODE" == "package-release" ]]; then
  BUILD_FLAGS=(-c release)
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
cleanup() {
  if [[ -n "$ICON_STAGING_DIR" && -d "$ICON_STAGING_DIR" ]]; then
    rm -rf "$ICON_STAGING_DIR"
  fi
  sakuracord_release_operation_lock
}
trap cleanup EXIT

sakuracord_print_identity

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

codesign --force --sign - --entitlements "$ROOT_DIR/Config/SakuraCord.entitlements" "$APP_BUNDLE" >/dev/null

open_app() {
  /usr/bin/open -n "$APP_BUNDLE" "$@"
  sakuracord_wait_for_scoped_app
}
open_offline_app() { open_app --args --offline; }
open_offline_long_server_list() { open_app --args --offline-long-server-list; }
open_offline_forum_performance() { open_app --args --offline-forum-performance; }

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
esac
