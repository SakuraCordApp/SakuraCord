#!/usr/bin/env bash
set -euo pipefail

CONTROL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ROOT_DIR="$CONTROL_ROOT"
BUILD=0
LAUNCH_ARGS=()
SIMULATOR=0
SIMULATOR_SCENARIO=""
SIMULATOR_SIGN_IN=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --checkout)
      [[ "$#" -ge 2 ]] || { echo "--checkout requires a directory." >&2; exit 2; }
      ROOT_DIR="$(cd "$2" && pwd -P)"
      shift 2
      ;;
    --build) BUILD=1; shift ;;
    --simulator)
      # Debug builds connect to the local Discord simulator instead of Discord.
      SIMULATOR=1
      if [[ "$#" -ge 2 && "$2" != --* ]]; then SIMULATOR_SCENARIO="$2"; shift; fi
      shift
      ;;
    --simulator-sign-in) SIMULATOR=1; SIMULATOR_SIGN_IN=1; shift ;;
    *)
      echo "usage: $0 [--checkout PATH] [--build] [--simulator [SCENARIO]|--simulator-sign-in]" >&2
      exit 2
      ;;
  esac
done

SAKURACORD_ROOT_DIR="$ROOT_DIR"
# shellcheck source=runtime.sh
source "$CONTROL_ROOT/script/runtime.sh"

if [[ "$BUILD" == "1" ]]; then
  sakuracord_resolve_insecure_debug_credentials "$ROOT_DIR"
  sakuracord_apply_secure_release_credential_policy package "${SAKURACORD_ENABLE_UPDATES:-0}"
  sakuracord_resolve_code_sign_identity 1
  # Older packagers may ignore machine preferences. Pass the resolved values
  # explicitly and retain launch ownership in this current, guarded runtime.
  SAKURACORD_ROOT_DIR="$ROOT_DIR" \
    SAKURACORD_INSECURE_DEBUG_CREDENTIALS="$SAKURACORD_RESOLVED_INSECURE_DEBUG_CREDENTIALS" \
    SAKURACORD_CODE_SIGN_IDENTITY="$SAKURACORD_RESOLVED_CODE_SIGN_IDENTITY" \
    "$ROOT_DIR/script/build_and_run.sh" package
fi

sakuracord_acquire_operation_lock
trap sakuracord_release_operation_lock EXIT

if ! grep -q '^sakuracord_select_app_variant()' "$ROOT_DIR/script/runtime.sh"; then
  # Checkouts before per-variant app names package debug builds as the product.
  SAKURACORD_APP_BUNDLE="$SAKURACORD_DIST_DIR/$SAKURACORD_PRODUCT_NAME.app"
  SAKURACORD_EXECUTABLE_PATH="$SAKURACORD_APP_BUNDLE/Contents/MacOS/$SAKURACORD_PRODUCT_NAME"
fi

if [[ ! -x "$SAKURACORD_EXECUTABLE_PATH" ]]; then
  echo "No built app at $SAKURACORD_APP_BUNDLE. Run ./script/build_and_run.sh package first." >&2
  exit 1
fi

if [[ "$SIMULATOR" == "1" ]]; then
  SIMULATOR_PORT="${SAKURACORD_DISCORD_SIMULATOR_PORT:-47100}"
  if [[ -n "$SIMULATOR_SCENARIO" ]] || ! "$CONTROL_ROOT/script/simulator.sh" status >/dev/null 2>&1; then
    "$CONTROL_ROOT/script/simulator.sh" start --scenario "${SIMULATOR_SCENARIO:-demo}"
  fi
  LAUNCH_ARGS=()
  if [[ "$SIMULATOR_SIGN_IN" == "1" ]]; then
    # Start signed out with first-run onboarding: clear the app's simulator
    # accounts, data and session defaults (never the real ones).
    sakuracord_stop_scoped_app || exit 1
    container="$HOME/Library/Containers/$SAKURACORD_BUNDLE_ID/Data/Library"
    rm -rf "$container/Application Support/SakuraCord/DiscordSimulator"
    defaults delete "$container/Preferences/dev.sakuracord.SakuraCord.discord-simulator" >/dev/null 2>&1 || true
  else
    LAUNCH_ARGS+=(--env "SAKURACORD_SIMULATOR_TOKEN=$("$CONTROL_ROOT/script/simulator.sh" token)")
  fi
  LAUNCH_ARGS+=(--args --discord-simulator "$SIMULATOR_PORT")
fi

sakuracord_launch_scoped_app ${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"}
