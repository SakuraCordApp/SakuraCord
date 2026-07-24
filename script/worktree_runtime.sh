#!/usr/bin/env bash

# Shared worktree identity and process helpers. This file is sourced by the
# setup, build, test, and cleanup entrypoints.

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "worktree_runtime.sh must run under Bash. Execute it directly; do not source it from zsh." >&2
  return 2 2>/dev/null || exit 2
fi

if [[ -n "${SAKURACORD_WORKTREE_RUNTIME_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
SAKURACORD_WORKTREE_RUNTIME_LOADED=1

SAKURACORD_ROOT_DIR="${SAKURACORD_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
SAKURACORD_PRODUCT_NAME="SakuraCord"
SAKURACORD_PACKAGE_DIR="$SAKURACORD_ROOT_DIR/App"
SAKURACORD_SCRATCH_DIR="$SAKURACORD_PACKAGE_DIR/.build"

sakuracord_absolute_git_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    (cd "$SAKURACORD_ROOT_DIR" && cd "$(dirname "$path")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")")
  fi
}

sakuracord_sanitize_identifier() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g' \
    | cut -c1-18
}

SAKURACORD_GIT_DIR="$(sakuracord_absolute_git_path "$(git -C "$SAKURACORD_ROOT_DIR" rev-parse --git-dir)")"
SAKURACORD_GIT_COMMON_DIR="$(sakuracord_absolute_git_path "$(git -C "$SAKURACORD_ROOT_DIR" rev-parse --git-common-dir)")"

if [[ "$SAKURACORD_GIT_DIR" == "$SAKURACORD_GIT_COMMON_DIR" ]]; then
  SAKURACORD_IS_MAIN_WORKTREE=1
  SAKURACORD_CHECKOUT_KIND="main"
  SAKURACORD_VARIANT_ID="main"
else
  SAKURACORD_IS_MAIN_WORKTREE=0
  SAKURACORD_CHECKOUT_KIND="linked"
  if [[ -n "${SAKURACORD_WORKTREE_ID:-}" ]]; then
    SAKURACORD_VARIANT_ID="$(sakuracord_sanitize_identifier "$SAKURACORD_WORKTREE_ID")"
  else
    worktree_label="$(sakuracord_sanitize_identifier "$(basename "$(dirname "$SAKURACORD_ROOT_DIR")")")"
    worktree_hash="$(printf '%s' "$SAKURACORD_ROOT_DIR" | shasum -a 256 | cut -c1-6)"
    if [[ -z "$worktree_label" ]]; then
      worktree_label="worktree"
    fi
    SAKURACORD_VARIANT_ID="$worktree_label-$worktree_hash"
  fi
fi

if [[ -z "$SAKURACORD_VARIANT_ID" ]]; then
  echo "SakuraCord worktree identity is empty." >&2
  return 2 2>/dev/null || exit 2
fi

if [[ "$SAKURACORD_IS_MAIN_WORKTREE" -eq 1 ]]; then
  SAKURACORD_APP_NAME="$SAKURACORD_PRODUCT_NAME"
  SAKURACORD_DISPLAY_NAME="$SAKURACORD_PRODUCT_NAME"
  SAKURACORD_BUNDLE_ID="dev.sakuracord.SakuraCord"
  SAKURACORD_DIST_DIR="$SAKURACORD_ROOT_DIR/dist"
else
  SAKURACORD_APP_NAME="$SAKURACORD_PRODUCT_NAME-$SAKURACORD_VARIANT_ID"
  SAKURACORD_DISPLAY_NAME="$SAKURACORD_PRODUCT_NAME [$SAKURACORD_VARIANT_ID]"
  SAKURACORD_BUNDLE_ID="dev.sakuracord.SakuraCord.worktree.w$SAKURACORD_VARIANT_ID"
  SAKURACORD_DIST_DIR="$SAKURACORD_ROOT_DIR/dist/worktrees/$SAKURACORD_VARIANT_ID"
fi

SAKURACORD_APP_BUNDLE="$SAKURACORD_DIST_DIR/$SAKURACORD_APP_NAME.app"
SAKURACORD_EXECUTABLE_PATH="$SAKURACORD_APP_BUNDLE/Contents/MacOS/$SAKURACORD_APP_NAME"
SAKURACORD_RUNTIME_DIR="$SAKURACORD_ROOT_DIR/.codex-runtime"
SAKURACORD_OPERATION_LOCK="$SAKURACORD_RUNTIME_DIR/operation.lock"
SAKURACORD_SWIFTPM_CACHE_DIR="$SAKURACORD_RUNTIME_DIR/swiftpm-cache"

sakuracord_scoped_pids() {
  # `-ww` is required for long Codex worktree paths. A truncated command would
  # make exact-path discovery miss the scoped process.
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
    echo "SakuraCord variant $SAKURACORD_VARIANT_ID did not exit after SIGTERM (PIDs: $remaining)." >&2
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
      echo "Another SakuraCord build or test is already using this worktree (PID $owner)." >&2
      return 75
    fi
    rm -f "$SAKURACORD_OPERATION_LOCK/pid"
    rmdir "$SAKURACORD_OPERATION_LOCK" 2>/dev/null || true
    if ! mkdir "$SAKURACORD_OPERATION_LOCK" 2>/dev/null; then
      echo "Could not recover the stale worktree operation lock." >&2
      return 75
    fi
  fi

  printf '%s\n' "$$" >"$SAKURACORD_OPERATION_LOCK/pid"
}

sakuracord_print_identity() {
  if [[ "$SAKURACORD_IS_MAIN_WORKTREE" -eq 1 ]]; then
    printf 'Checkout:  main (canonical identity; linked-worktree isolation inactive)\n'
  else
    printf 'Checkout:  linked worktree (isolated identity active)\n'
  fi
  printf 'Root:      %s\n' "$SAKURACORD_ROOT_DIR"
  printf 'Variant:  %s\n' "$SAKURACORD_VARIANT_ID"
  printf 'App:      %s\n' "$SAKURACORD_APP_BUNDLE"
  printf 'Bundle ID:%s\n' " $SAKURACORD_BUNDLE_ID"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  sakuracord_print_identity
fi
