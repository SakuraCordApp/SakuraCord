#!/usr/bin/env bash

# Shared canonical app identity and process helpers for build, test, package,
# release, and profiling entrypoints.

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "runtime.sh must run under Bash. Execute it directly; do not source it from zsh." >&2
  return 2 2>/dev/null || exit 2
fi

if [[ -n "${SAKURACORD_RUNTIME_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
SAKURACORD_RUNTIME_LOADED=1

SAKURACORD_ROOT_DIR="${SAKURACORD_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
SAKURACORD_PRODUCT_NAME="SakuraCord"
SAKURACORD_BUNDLE_ID="dev.sakuracord.SakuraCord"
SAKURACORD_PACKAGE_DIR="$SAKURACORD_ROOT_DIR/App"
SAKURACORD_SCRATCH_DIR="$SAKURACORD_PACKAGE_DIR/.build"
SAKURACORD_DIST_DIR="$SAKURACORD_ROOT_DIR/dist"

# Selects the app name, bundle path, and icon for a build configuration
# (debug|release) and release track (regular|nightly). Debug builds are
# "SakuraCord Debug", nightly release builds are "SakuraCord Nightly", and
# regular release builds keep the product name.
sakuracord_select_app_variant() {
  local configuration="$1"
  local track="${2:-regular}"
  if [[ "$configuration" == "debug" ]]; then
    SAKURACORD_APP_VARIANT=debug
    SAKURACORD_APP_NAME="$SAKURACORD_PRODUCT_NAME Debug"
    SAKURACORD_APP_ICON_SOURCE="$SAKURACORD_PRODUCT_NAME Debug.icon"
  elif [[ "$track" == "nightly" ]]; then
    SAKURACORD_APP_VARIANT=nightly
    SAKURACORD_APP_NAME="$SAKURACORD_PRODUCT_NAME Nightly"
    SAKURACORD_APP_ICON_SOURCE="$SAKURACORD_PRODUCT_NAME Nightly.icon"
  else
    SAKURACORD_APP_VARIANT=release
    SAKURACORD_APP_NAME="$SAKURACORD_PRODUCT_NAME"
    SAKURACORD_APP_ICON_SOURCE="$SAKURACORD_PRODUCT_NAME.icon"
  fi
  SAKURACORD_DISPLAY_NAME="$SAKURACORD_APP_NAME"
  SAKURACORD_APP_BUNDLE="$SAKURACORD_DIST_DIR/$SAKURACORD_APP_NAME.app"
  SAKURACORD_EXECUTABLE_PATH="$SAKURACORD_APP_BUNDLE/Contents/MacOS/$SAKURACORD_APP_NAME"
}
# Development launches, Computer Use, and profiling target the debug build.
sakuracord_select_app_variant debug

SAKURACORD_RUNTIME_DIR="$SAKURACORD_ROOT_DIR/.codex-runtime"
SAKURACORD_OPERATION_LOCK="$SAKURACORD_RUNTIME_DIR/operation.lock"
SAKURACORD_SWIFTPM_CACHE_DIR="$SAKURACORD_RUNTIME_DIR/swiftpm-cache"
# Resolve helpers beside this runtime, even when targeting an older checkout.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/development_launch.sh"

# Debug builds from every checkout share one bundle identifier and account
# state, so the debug variant matches all of them to keep a single instance.
# Other variants match only this checkout's bundle, never an installed app.
sakuracord_scoped_pids() {
  ps -ww -axo pid=,comm= | while read -r pid executable; do
    if [[ "$executable" == "$SAKURACORD_EXECUTABLE_PATH" ]] \
      || [[ "$SAKURACORD_APP_VARIANT" == debug && "$executable" == /*"/$SAKURACORD_APP_NAME.app/Contents/MacOS/$SAKURACORD_APP_NAME" ]]; then
      printf '%s\n' "$pid"
    fi
  done
}

sakuracord_is_scoped_app_running() {
  [[ -n "$(sakuracord_scoped_pids)" ]]
}

sakuracord_stop_scoped_app() {
  local pid
  local remaining
  local attempts=0

  for pid in $(sakuracord_scoped_pids); do
    kill "$pid" 2>/dev/null || true
  done

  while sakuracord_is_scoped_app_running && [[ "$attempts" -lt 50 ]]; do
    sleep 0.1
    attempts=$((attempts + 1))
  done

  remaining="$(sakuracord_scoped_pids)"
  if [[ -n "$remaining" ]]; then
    echo "SakuraCord did not exit after SIGTERM (PIDs: $remaining)." >&2
    return 1
  fi
}

sakuracord_wait_for_scoped_app() {
  local attempts=0
  while ! sakuracord_is_scoped_app_running && [[ "$attempts" -lt 100 ]]; do
    sleep 0.1
    attempts=$((attempts + 1))
  done
  sakuracord_is_scoped_app_running
}

sakuracord_launch_scoped_app() {
  sakuracord_verify_development_launch || return
  # A launcher can reopen the old app while compilation or packaging runs.
  # Check again at launch time, and let LaunchServices reuse an instance if
  # another launcher races this final check instead of forcing a duplicate.
  sakuracord_stop_scoped_app || return
  /usr/bin/open "$SAKURACORD_APP_BUNDLE" "$@" || return
  sakuracord_wait_for_scoped_app || return

  local pids
  pids="$(sakuracord_scoped_pids)"
  if [[ -z "$pids" || "$pids" == *$'\n'* ]] \
    || [[ "$(ps -o comm= -p "$pids")" != "$SAKURACORD_EXECUTABLE_PATH" ]]; then
    echo "Expected one $SAKURACORD_APP_NAME instance, from this checkout, after launch (PIDs: $pids)." >&2
    return 1
  fi
}

sakuracord_release_operation_lock() {
  if [[ -f "$SAKURACORD_OPERATION_LOCK/pid" ]] \
    && [[ "$(cat "$SAKURACORD_OPERATION_LOCK/pid" 2>/dev/null || true)" == "$$" ]]; then
    rm -f "$SAKURACORD_OPERATION_LOCK/pid"
    rmdir "$SAKURACORD_OPERATION_LOCK" 2>/dev/null || true
  fi
}

sakuracord_acquire_operation_lock() {
  local owner=""
  mkdir -p "$SAKURACORD_RUNTIME_DIR"

  if ! mkdir "$SAKURACORD_OPERATION_LOCK" 2>/dev/null; then
    owner="$(cat "$SAKURACORD_OPERATION_LOCK/pid" 2>/dev/null || true)"
    if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
      echo "Another SakuraCord build or test is already running (PID $owner)." >&2
      return 75
    fi
    rm -f "$SAKURACORD_OPERATION_LOCK/pid"
    rmdir "$SAKURACORD_OPERATION_LOCK" 2>/dev/null || true
    if ! mkdir "$SAKURACORD_OPERATION_LOCK" 2>/dev/null; then
      echo "Could not recover the stale SakuraCord operation lock." >&2
      return 75
    fi
  fi

  printf '%s\n' "$$" >"$SAKURACORD_OPERATION_LOCK/pid"
}

sakuracord_print_identity() {
  printf 'Root:      %s\n' "$SAKURACORD_ROOT_DIR"
  printf 'App:       %s\n' "$SAKURACORD_APP_BUNDLE"
  printf 'Bundle ID: %s\n' "$SAKURACORD_BUNDLE_ID"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  sakuracord_print_identity
fi
