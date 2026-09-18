#!/usr/bin/env bash

# Shared canonical app identity and process helpers for build, test, package,
# release, and profiling entrypoints.

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "runtime.sh must run under Bash. Execute it directly; do not source it from zsh." >&2
  return 2 2>/dev/null || exit 2
fi

if [[ -n "${MARROWCHAT_RUNTIME_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
MARROWCHAT_RUNTIME_LOADED=1

MARROWCHAT_ROOT_DIR="${MARROWCHAT_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
MARROWCHAT_PRODUCT_NAME="MarrowChat"
MARROWCHAT_APP_NAME="$MARROWCHAT_PRODUCT_NAME"
MARROWCHAT_DISPLAY_NAME="$MARROWCHAT_PRODUCT_NAME"
MARROWCHAT_BUNDLE_ID="dev.marrowchat.MarrowChat"
MARROWCHAT_PACKAGE_DIR="$MARROWCHAT_ROOT_DIR/App"
MARROWCHAT_SCRATCH_DIR="$MARROWCHAT_PACKAGE_DIR/.build"
MARROWCHAT_DIST_DIR="$MARROWCHAT_ROOT_DIR/dist"
MARROWCHAT_APP_BUNDLE="$MARROWCHAT_DIST_DIR/$MARROWCHAT_APP_NAME.app"
MARROWCHAT_EXECUTABLE_PATH="$MARROWCHAT_APP_BUNDLE/Contents/MacOS/$MARROWCHAT_APP_NAME"
MARROWCHAT_RUNTIME_DIR="$MARROWCHAT_ROOT_DIR/.codex-runtime"
MARROWCHAT_OPERATION_LOCK="$MARROWCHAT_RUNTIME_DIR/operation.lock"
MARROWCHAT_SWIFTPM_CACHE_DIR="$MARROWCHAT_RUNTIME_DIR/swiftpm-cache"

marrowchat_scoped_pids() {
  ps -ww -axo pid=,command= | while read -r pid command; do
    if [[ "$command" == "$MARROWCHAT_EXECUTABLE_PATH" || "$command" == "$MARROWCHAT_EXECUTABLE_PATH "* ]]; then
      printf '%s\n' "$pid"
    fi
  done
}

marrowchat_is_scoped_app_running() {
  [[ -n "$(marrowchat_scoped_pids)" ]]
}

marrowchat_stop_scoped_app() {
  local pid
  local remaining
  local attempts=0

  for pid in $(marrowchat_scoped_pids); do
    kill "$pid" 2>/dev/null || true
  done

  while marrowchat_is_scoped_app_running && [[ "$attempts" -lt 50 ]]; do
    sleep 0.1
    attempts=$((attempts + 1))
  done

  remaining="$(marrowchat_scoped_pids)"
  if [[ -n "$remaining" ]]; then
    echo "MarrowChat did not exit after SIGTERM (PIDs: $remaining)." >&2
    return 1
  fi
}

marrowchat_wait_for_scoped_app() {
  local attempts=0
  while ! marrowchat_is_scoped_app_running && [[ "$attempts" -lt 100 ]]; do
    sleep 0.1
    attempts=$((attempts + 1))
  done
  marrowchat_is_scoped_app_running
}

marrowchat_release_operation_lock() {
  if [[ -f "$MARROWCHAT_OPERATION_LOCK/pid" ]] \
    && [[ "$(cat "$MARROWCHAT_OPERATION_LOCK/pid" 2>/dev/null || true)" == "$$" ]]; then
    rm -f "$MARROWCHAT_OPERATION_LOCK/pid"
    rmdir "$MARROWCHAT_OPERATION_LOCK" 2>/dev/null || true
  fi
}

marrowchat_acquire_operation_lock() {
  local owner=""
  mkdir -p "$MARROWCHAT_RUNTIME_DIR"

  if ! mkdir "$MARROWCHAT_OPERATION_LOCK" 2>/dev/null; then
    owner="$(cat "$MARROWCHAT_OPERATION_LOCK/pid" 2>/dev/null || true)"
    if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
      echo "Another MarrowChat build or test is already running (PID $owner)." >&2
      return 75
    fi
    rm -f "$MARROWCHAT_OPERATION_LOCK/pid"
    rmdir "$MARROWCHAT_OPERATION_LOCK" 2>/dev/null || true
    if ! mkdir "$MARROWCHAT_OPERATION_LOCK" 2>/dev/null; then
      echo "Could not recover the stale MarrowChat operation lock." >&2
      return 75
    fi
  fi

  printf '%s\n' "$$" >"$MARROWCHAT_OPERATION_LOCK/pid"
}

marrowchat_print_identity() {
  printf 'Root:      %s\n' "$MARROWCHAT_ROOT_DIR"
  printf 'App:       %s\n' "$MARROWCHAT_APP_BUNDLE"
  printf 'Bundle ID: %s\n' "$MARROWCHAT_BUNDLE_ID"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  marrowchat_print_identity
fi
