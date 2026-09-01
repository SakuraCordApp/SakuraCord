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
SAKURACORD_APP_NAME="$SAKURACORD_PRODUCT_NAME"
SAKURACORD_DISPLAY_NAME="$SAKURACORD_PRODUCT_NAME"
SAKURACORD_BUNDLE_ID="dev.sakuracord.SakuraCord"
SAKURACORD_PACKAGE_DIR="$SAKURACORD_ROOT_DIR/App"
SAKURACORD_SCRATCH_DIR="$SAKURACORD_PACKAGE_DIR/.build"
SAKURACORD_DIST_DIR="$SAKURACORD_ROOT_DIR/dist"
SAKURACORD_APP_BUNDLE="$SAKURACORD_DIST_DIR/$SAKURACORD_APP_NAME.app"
SAKURACORD_EXECUTABLE_PATH="$SAKURACORD_APP_BUNDLE/Contents/MacOS/$SAKURACORD_APP_NAME"
SAKURACORD_RUNTIME_DIR="$SAKURACORD_ROOT_DIR/.codex-runtime"
SAKURACORD_OPERATION_LOCK="$SAKURACORD_RUNTIME_DIR/operation.lock"
SAKURACORD_SWIFTPM_CACHE_DIR="$SAKURACORD_RUNTIME_DIR/swiftpm-cache"

sakuracord_scoped_pids() {
  ps -ww -axo pid=,command= | while read -r pid command; do
    if [[ "$command" == "$SAKURACORD_EXECUTABLE_PATH" || "$command" == "$SAKURACORD_EXECUTABLE_PATH "* ]]; then
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
