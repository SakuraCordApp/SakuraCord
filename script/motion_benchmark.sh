#!/usr/bin/env bash
set -euo pipefail

# SakuraCord side chat motion benchmark
#
# Builds a benchmark build, then launches it in the offline side chat motion
# fixture. The app opens, closes and widens fixture threads and toggles the
# member list while recording every display-link frame with the workspace
# geometry, then this script analyzes the recording with
# motion_benchmark_analyze.py.
#
# The benchmark exists only in builds made with SAKURACORD_MOTION_BENCHMARK=1,
# which this script sets when it builds. A benchmark build is a developer
# tool, not a release build: never ship it. It is packaged to the same dist/
# path as a normal build, so package again without the variable before using
# that app for anything else.
#
# Usage: script/motion_benchmark.sh [options] [-- analyzer options]
#   --release              Build and measure dist/SakuraCord.app
#                          (package-release) instead of the debug app.
#   --no-build             Measure the app already in dist/ without building.
#                          It must be a benchmark build.
#   --app PATH             Measure an explicit benchmark build; implies
#                          --no-build.
#   --label NAME           Artifact directory label. Default: configuration.
#   --cycles N             Animated cycles. Default: 6.
#   --history-delay-ms N   Simulated thread history latency. Default: 120, so
#                          messages arrive while the pane opens.
#   --thread-messages N    Messages per fixture thread. Default: 150.
#   --runs N               Repeat the launch N times. Default: 1.
#   --compare FILE         Print a before/after table against an earlier
#                          analysis.json.
#   --trace-schema NAME    Also export this table of the trace, for example
#                          swiftui-updates with --trace SwiftUI. Repeatable.
#   --app-arg ARG          Pass ARG to the app, for example
#                          --motion-forum-cycles=0. Repeatable.
#   --quiet-machine        Hold this checkout's operation lock while measuring,
#                          and SAKURACORD_BENCHMARK_MACHINE_LOCK (a lock
#                          directory that machine-wide builds respect) if set.
#   --trace TEMPLATE       Attach xctrace (for example "Time Profiler" or
#                          "Animation Hitches") once the animated cycles
#                          begin. Forces --runs 1. Exports the os-signpost,
#                          time-profile and hitches tables plus the table of
#                          contents, deletes the trace bundle and Instruments
#                          temporary files, and writes profile.txt with
#                          per-action hot frames and hitches.
#   --trace-seconds N      Trace length. Default: 18, at most 20.
#
# Artifacts are written beneath .build/performance/motion and remain untracked.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=runtime.sh
source "$root/script/runtime.sh"

configuration=debug
app=""
build=1
label=""
cycles=6
history_delay=120
thread_messages=150
runs=1
compare=""
quiet_machine=0
app_arguments=()
trace_schemas=()
trace=""
trace_seconds=18
analyzer_arguments=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) configuration=release ;;
        --no-build) build=0 ;;
        --app) app="$2"; build=0; shift ;;
        --label) label="$2"; shift ;;
        --cycles) cycles="$2"; shift ;;
        --history-delay-ms) history_delay="$2"; shift ;;
        --thread-messages) thread_messages="$2"; shift ;;
        --runs) runs="$2"; shift ;;
        --compare) compare="$2"; shift ;;
        --quiet-machine) quiet_machine=1 ;;
        --app-arg) app_arguments+=("$2"); shift ;;
        --trace-schema) trace_schemas+=("$2"); shift ;;
        --trace) trace="$2"; shift ;;
        --trace-seconds) trace_seconds="$2"; shift ;;
        --) shift; analyzer_arguments=("$@"); break ;;
        -h|--help) sed -n '/^# SakuraCord side chat/,/^# Artifacts/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 64 ;;
    esac
    shift
done

if [[ -z "$app" ]]; then
    sakuracord_select_app_variant "$configuration" "${SAKURACORD_RELEASE_TRACK:-regular}"
    app="$SAKURACORD_APP_BUNDLE"
fi
if [[ "$build" == 1 ]]; then
    package_mode=package
    [[ "$configuration" == release ]] && package_mode=package-release
    echo "Building a motion benchmark build (SAKURACORD_MOTION_BENCHMARK=1), not a release build." >&2
    SAKURACORD_MOTION_BENCHMARK=1 "$root/script/build_and_run.sh" "$package_mode"
fi
[[ -d "$app" ]] || { echo "No app bundle at $app; build it first (omit --no-build)." >&2; exit 2; }
if [[ -n "$trace" ]]; then
    runs=1
    [[ "$trace_seconds" =~ ^[0-9]+$ && "$trace_seconds" -ge 1 ]] \
        || { echo "--trace-seconds needs a positive integer." >&2; exit 64; }
    # Traces can grow to many GB; never record longer than 20 seconds.
    if (( trace_seconds > 20 )); then trace_seconds=20; fi
fi
executable_name="$(plutil -extract CFBundleExecutable raw -o - "$app/Contents/Info.plist")"
executable="$app/Contents/MacOS/$executable_name"
if ! grep -rqa SIDE_CHAT_MOTION_BENCHMARK_DONE "$app/Contents/MacOS" "$app/Contents/Frameworks" 2>/dev/null; then
    echo "$app is not a benchmark build (build it with SAKURACORD_MOTION_BENCHMARK=1)." >&2
    exit 2
fi
label="${label:-$configuration}"
output="$root/.build/performance/motion/$label-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$output"
trace_scratch=""
trace_pid=""
trace_recorded=0
if [[ -n "$trace" ]]; then
    if pgrep -x xctrace >/dev/null; then
        echo "Another xctrace process is active; refusing an ambiguous trace." >&2
        exit 3
    fi
fi

# A machine-wide build lock directory, when the machine has one, that builds
# wait for while it exists. --quiet-machine holds it with a process of its own.
machine_lock="${SAKURACORD_BENCHMARK_MACHINE_LOCK:-}"
holder=""
holds_operation_lock=0
release_machine() {
    if [[ -n "$holder" ]]; then
        kill "$holder" 2>/dev/null || true
        rm -rf "$machine_lock"
        holder=""
    fi
    if [[ "$holds_operation_lock" == 1 ]]; then
        sakuracord_release_operation_lock
        holds_operation_lock=0
    fi
}
stop_app() {
    local pid
    for pid in $(pgrep -f "^$executable( |$)" || true); do
        kill "$pid" 2>/dev/null || true
    done
    for _ in {1..50}; do
        pgrep -f "^$executable( |$)" >/dev/null || return 0
        sleep 0.1
    done
    echo "The benchmark app did not exit." >&2
    return 1
}
# Remove the trace bundle and the private scratch folder xctrace used as its
# temporary directory. Nothing outside this run's output folder is touched.
discard_trace_files() {
    [[ "$trace_recorded" == 1 ]] || return 0
    rm -rf "$output/trace.trace"
    [[ -n "$trace_scratch" ]] && rm -rf "$trace_scratch"
    return 0
}
export_trace_tables() {
    local trace_file="$1" schema
    xcrun xctrace export --input "$trace_file" --toc \
        --output "$output/toc.xml" >/dev/null 2>&1 || true
    for schema in os-signpost time-profile hitches ${trace_schemas[@]+"${trace_schemas[@]}"}; do
        xcrun xctrace export --input "$trace_file" \
            --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$schema\"]" \
            --output "$output/$schema.xml" >/dev/null 2>&1 || true
    done
    [[ -f "$output/os-signpost.xml" ]] \
        && mv "$output/os-signpost.xml" "$output/signposts.xml"
    return 0
}
record_trace() {
    local pid
    for _ in $(seq 1 100); do
        pid="$(pgrep -f "^$executable( |$)" | head -1 || true)"
        [[ -n "$pid" ]] && break
        sleep 0.1
    done
    if [[ -z "$pid" ]]; then
        echo "Could not find the benchmark app to trace." >&2
        return 1
    fi
    if pgrep -x xctrace >/dev/null; then
        echo "Another xctrace process is active; skipping the trace." >&2
        return 1
    fi
    echo "Tracing $executable_name ($pid) with $trace for ${trace_seconds}s…"
    trace_scratch="$output/xctrace-scratch"
    rm -rf "$trace_scratch"
    mkdir -p "$trace_scratch"
    TMPDIR="$trace_scratch/" xcrun xctrace record --template "$trace" --attach "$pid" \
        --time-limit "${trace_seconds}s" --output "$output/trace.trace" \
        > "$output/xctrace.log" 2>&1 &
    trace_pid=$!
    trace_recorded=1
    wait "$trace_pid" || echo "xctrace exited with an error; see $output/xctrace.log" >&2
    trace_pid=""
    [[ -d "$output/trace.trace" ]] || return 1
    export_trace_tables "$output/trace.trace"
    discard_trace_files
    python3 "$root/script/motion_benchmark_profile.py" \
        --signposts "$output/signposts.xml" \
        --time-profile "$output/time-profile.xml" \
        --hitches "$output/hitches.xml" \
        --process "$executable_name" \
        > "$output/profile.txt" 2>&1 || true
    cat "$output/profile.txt"
}
cleanup() {
    if [[ -n "$trace_pid" ]]; then
        kill -INT "$trace_pid" 2>/dev/null || true
        wait "$trace_pid" 2>/dev/null || true
    fi
    discard_trace_files
    stop_app || true
    release_machine
    [[ -n "${stream_pid:-}" ]] && kill "$stream_pid" 2>/dev/null || true
}
trap cleanup EXIT

if [[ "$quiet_machine" == 1 ]]; then
    # No build or test of this checkout starts while measuring.
    until sakuracord_acquire_operation_lock 2>/dev/null; do
        echo "Waiting for this checkout's build or test…" >&2
        sleep 30
    done
    holds_operation_lock=1
    if [[ -n "$machine_lock" ]]; then
        until mkdir "$machine_lock" 2>/dev/null; do
            echo "Waiting for the machine's build lock…" >&2
            sleep 30
        done
        sleep 900 &
        holder=$!
        echo "$holder" > "$machine_lock/pid"
    fi
fi

for run in $(seq 1 "$runs"); do
    stop_app
    log="$output/run-$run.log"
    /usr/bin/log stream --style compact \
        --predicate 'subsystem == "dev.sakuracord.SakuraCord" AND category == "SideChatMotionBenchmark"' \
        > "$log" 2>&1 &
    stream_pid=$!
    sleep 1
    /usr/bin/open -n -F "$app" --args --offline-side-chat-motion \
        "--motion-cycles=$cycles" \
        "--motion-history-delay-ms=$history_delay" \
        "--motion-thread-messages=$thread_messages" ${app_arguments[@]+"${app_arguments[@]}"}
    if [[ -n "$trace" ]]; then
        for _ in $(seq 1 $((60 + cycles * 5))); do
            grep -q "SIDE_CHAT_MOTION_CYCLES_BEGIN" "$log" && break
            grep -q "SIDE_CHAT_MOTION_BENCHMARK_FAILED" "$log" && break
            sleep 1
        done
        if grep -q "SIDE_CHAT_MOTION_CYCLES_BEGIN" "$log"; then
            record_trace || echo "No trace was recorded." >&2
        else
            echo "The animated cycles never began; skipping the trace." >&2
        fi
    fi
    recording=""
    for _ in $(seq 1 $((120 + cycles * 15))); do
        if grep -q "SIDE_CHAT_MOTION_BENCHMARK_FAILED" "$log"; then break; fi
        recording="$(sed -n 's/.*SIDE_CHAT_MOTION_BENCHMARK_DONE \(.*\)$/\1/p' "$log" | tail -1)"
        [[ -n "$recording" ]] && break
        sleep 1
    done
    kill "$stream_pid" 2>/dev/null || true
    stream_pid=""
    stop_app
    if [[ -z "$recording" || ! -f "$recording" ]]; then
        echo "Run $run produced no recording; see $log" >&2
        exit 1
    fi
    cp "$recording" "$output/recording-$run.json"
    echo "Run $run: $output/recording-$run.json"
done
release_machine

recordings=("$output"/recording-*.json)
arguments=(--json "$output/analysis.json" --html "$output/report.html")
[[ -n "$compare" ]] && arguments+=(--compare "$compare")
python3 "$root/script/motion_benchmark_analyze.py" "${recordings[@]}" \
    "${arguments[@]}" ${analyzer_arguments[@]+"${analyzer_arguments[@]}"} \
    | tee "$output/report.txt"
echo "Artifacts: $output"
