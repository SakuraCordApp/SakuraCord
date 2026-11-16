#!/usr/bin/env bash
# Builds, starts, stops and queries the local Discord simulator.
#
#   script/simulator.sh start [--scenario NAME] [--seed N] [--network PROFILE] [--port N] [--param k=v]... [--freeze-clock]
#   script/simulator.sh stop | status | token | build | ctl <discord-simctl arguments>
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PACKAGE_DIR="$ROOT_DIR/Packages/DiscordSimulator"
RUNTIME_DIR="$ROOT_DIR/.codex-runtime/discord-simulator"
PID_FILE="$RUNTIME_DIR/simulator.pid"
LOG_FILE="$RUNTIME_DIR/simulator.log"
PORT="${SAKURACORD_DISCORD_SIMULATOR_PORT:-47100}"
mkdir -p "$RUNTIME_DIR"

bin_dir() {
  swift build --package-path "$PACKAGE_DIR" --scratch-path "$PACKAGE_DIR/.build" -c release --show-bin-path
}

build() {
  swift build --package-path "$PACKAGE_DIR" --scratch-path "$PACKAGE_DIR/.build" -c release \
    --product discord-simulator >&2
  swift build --package-path "$PACKAGE_DIR" --scratch-path "$PACKAGE_DIR/.build" -c release \
    --product discord-simctl >&2
}

running_pid() {
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null \
    && [[ "$(ps -o comm= -p "$pid")" == */discord-simulator ]]; then
    echo "$pid"
  fi
}

control() {
  curl -fsS "http://127.0.0.1:$((PORT + 9))/control/$1"
}

stop() {
  local pid
  pid="$(running_pid)"
  [[ -n "$pid" ]] || return 0
  kill "$pid"
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  rm -f "$PID_FILE"
}

start() {
  local arguments=(--port "$PORT")
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --port) PORT="$2"; arguments=(--port "$PORT"); shift 2 ;;
      --scenario|--seed|--network|--param) arguments+=("$1" "$2"); shift 2 ;;
      --freeze-clock|--no-rate-limits|--verbose) arguments+=("$1"); shift ;;
      *) echo "simulator.sh start: unknown option $1" >&2; exit 2 ;;
    esac
  done
  stop
  build
  local executable
  executable="$(bin_dir)/discord-simulator"
  nohup "$executable" "${arguments[@]}" >"$LOG_FILE" 2>&1 &
  echo "$!" >"$PID_FILE"
  for _ in $(seq 1 300); do
    if control health >/dev/null 2>&1; then
      grep -E '^(scenario|api|account):' "$LOG_FILE" >&2 || true
      return 0
    fi
    if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "discord-simulator exited during startup:" >&2
      cat "$LOG_FILE" >&2
      return 1
    fi
    sleep 0.1
  done
  echo "discord-simulator did not become ready; log: $LOG_FILE" >&2
  return 1
}

case "${1:-}" in
  build) build ;;
  start) shift; start "$@" ;;
  stop) stop ;;
  status)
    if [[ -n "$(running_pid)" ]]; then control health; echo; else echo "not running"; exit 1; fi
    ;;
  token)
    control world | python3 -c 'import json,sys; print(json.load(sys.stdin)["accounts"][0]["token"])'
    ;;
  ctl)
    shift
    "$(bin_dir)/discord-simctl" --port "$PORT" "$@"
    ;;
  *)
    sed -n '2,6p' "$0" >&2
    exit 2
    ;;
esac
