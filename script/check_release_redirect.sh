#!/usr/bin/env bash
# Fails if a built SakuraCord binary contains the debug-only Discord simulator
# redirect: its host table, launch flag, token variable or account storage.
# `build_and_run.sh package-release` runs it on every release package.
#
#   script/check_release_redirect.sh <path to SakuraCord.app or its executable>
set -euo pipefail

target="${1:?usage: $0 <SakuraCord.app or executable>}"
if [[ -d "$target" ]]; then
  executable="$target/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$target/Contents/Info.plist")"
else
  executable="$target"
fi
[[ -f "$executable" ]] || { echo "No executable at $executable" >&2; exit 2; }

markers=(
  "--discord-simulator"
  "SAKURACORD_DISCORD_SIMULATOR"
  "SAKURACORD_SIMULATOR_TOKEN"
  "discord-attachments-uploads-prd.storage.googleapis.com"
  "dev.sakuracord.SakuraCord.discord-simulator"
  "DiscordSimulator"
)
# Read the binary once: `strings | grep -q` under pipefail reports a match as
# a failure when grep exits early and strings dies of SIGPIPE.
strings_out="$(strings -a "$executable")"
symbols_out="$(nm -a "$executable" 2>/dev/null || true)"
found=0
for marker in "${markers[@]}"; do
  if grep -qF -- "$marker" <<< "$strings_out"; then
    echo "found string: $marker" >&2
    found=1
  fi
done
# SimulatorAccountStorage stays in release builds (always inactive), so only
# debug-only redirect symbols count.
for symbol in simulatorBasePort portOffset simulatorDefaultsSuite; do
  if grep -q "$symbol" <<< "$symbols_out"; then
    echo "found symbol: $symbol" >&2
    found=1
  fi
done
if [[ "$found" == "1" ]]; then
  echo "FAIL: $executable contains the simulator redirect." >&2
  exit 1
fi
echo "OK: no simulator redirect in $executable"
