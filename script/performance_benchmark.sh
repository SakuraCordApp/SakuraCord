#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime="$("$root/script/runtime.sh")"
canonical_app="$(sed -n 's/^App:  *//p' <<<"$runtime")"
app="${SAKURACORD_PERFORMANCE_APP_OVERRIDE:-$canonical_app}"
bundle_id="$(sed -n 's/^Bundle ID:  *//p' <<<"$runtime")"
executable="${SAKURACORD_PERFORMANCE_EXECUTABLE_OVERRIDE:-$app/Contents/MacOS/SakuraCord}"
provenance_directory="${SAKURACORD_PERFORMANCE_PROVENANCE_DIRECTORY_OVERRIDE:-$root/.build/performance-tools/build-provenance}"
source_root="${SAKURACORD_PERFORMANCE_SOURCE_ROOT_OVERRIDE:-$root}"

usage() {
    sed -n \
        '/^# SakuraCord performance benchmark harness/,/^# Artifacts/p' \
        "$0" | sed 's/^# \{0,1\}//'
}

# SakuraCord performance benchmark harness
#
# Commands:
#   build
#       Rebuild and launch the canonical authenticated debug app with the
#       local insecure-debug credential mode required for profiling.
#   record <scenario> [seconds] [template]
#       Attach to the exact running app. Simultaneously captures the chosen
#       Instruments template, CPU/RSS samples, macOS per-process energy and
#       wakeup counters, and per-process network counters. Perform only
#       read-only UI actions.
#       Defaults: 30 seconds, "Time Profiler".
#       Use "Activity Monitor" for native process footprint, wakeup, and disk
#       counters. Apple's "Power Profiler" template is not supported on macOS.
#   startup [seconds]
#       Relaunch the exact canonical app under an all-process Time Profiler
#       recording so initialization signposts and CPU samples are captured
#       from process birth. Exact process energy, wakeup, and footprint metrics
#       are intentionally not claimed for startup because an external sampler
#       cannot attach before the process begins. Defaults: 12 seconds.
#   authenticated-scroll [seconds]
#       Relaunch the authenticated debug app and run its deterministic native
#       20-second display-link scroll workload in the persisted selected channel.
#       Delayed frames remain reportable; spatial distance, deficit from the
#       nominal 24,000-point path, and quality ratio are recorded separately.
#       Before measurement the app read-only loads up to five older pages until
#       the native timeline has at least 100 messages. This never synthesizes user
#       interaction, marks content read, sends a message, or enables an offline
#       fixture. Set SAKURACORD_PERFORMANCE_ACCOUNT_ID to a stored debug account
#       ID to compare accounts; otherwise the most recently selected account is
#       used. Defaults: 35 seconds.
#   authenticated-member-list-scroll [seconds]
#       Relaunch the authenticated debug app and run the same deterministic
#       20-second display-link workload through the native member list. The
#       workload waits until you select a real server exposing at least 24,000
#       points of authoritative member-list rows. Server selection and viewport
#       subscriptions are read-only; this scenario never sends messages,
#       acknowledgements, reactions, or account mutations. Defaults: 70 seconds
#       so an authenticated workspace can be selected before measurement.
#   authenticated-gesture-scroll [seconds]
#       Relaunch the authenticated debug app with benchmark-only gesture probes
#       on the message timeline, member list, channel list, and server list.
#       Use real trackpad gestures while recording; each new gesture or momentum
#       boundary records event-to-moving-frame latency. This scenario performs
#       no synthetic input or account mutation. The exact 20-second interaction
#       window begins after the initial conversation is ready. Defaults: 40 seconds.
#   authenticated-loading-scroll-overlap [seconds] [surface]
#       Relaunch with gesture probes, hold an eight-second idle scrolling control,
#       then cold-open the real Google Labs server and load its initial members,
#       roles, messages, first frame, and additional history in one exact window.
#       Start continuous read-only trackpad scrolling when the workspace appears
#       and keep scrolling the selected timeline, member-list, channel-list, or
#       server-list surface through the loading phase. Run once per surface; the
#       summary rejects missing idle/loading gesture samples or a final history
#       count that did not grow beyond the initial page. Defaults: 55 seconds and
#       timeline.
#   authenticated-navigation [seconds]
#       Relaunch the authenticated debug app and deterministically open real
#       DMs, servers, and same-server channels using live REST and Gateway data.
#       The workload disables acknowledgements and all account mutations. It
#       records request, decode, member hydration, state commit, rendering, and
#       first-frame stages inside one exact resource window. Defaults: 45 seconds.
#   authenticated-account-switch [seconds]
#       Relaunch with one stored debug account, switch to a second real account,
#       and measure shutdown, authentication, Gateway bootstrap, state application,
#       destination history, and its first rendered frame. Discord-side activity is
#       read-only, and the prior local preferred-account setting is restored after
#       the run. Requires at least two stored debug accounts. Defaults: 45 seconds.
#   authenticated-history-pagination [seconds]
#       Relaunch the authenticated debug app, select a real readable channel with
#       older history, and load up to five live 20-message pages. Records network,
#       member hydration, row preparation, state commit, rendering, and exact
#       process resources. This is read-only. Defaults: 45 seconds.
#   authenticated-search [seconds]
#       Relaunch the authenticated debug app for a read-only search comparison.
#       During the recording, submit one representative server or DM search in
#       the UI. Request-to-render latency and exact-window CPU, memory, wakeup,
#       and energy metrics are bounded by MessageSearchBenchmark signposts.
#       Defaults: 45 seconds.
#   authenticated-search-pagination [seconds]
#       Submit an initial search, then select another result page. Measures the
#       pagination request through rendered results and its exact resources.
#   authenticated-search-scroll [seconds]
#       Submit a search, then scroll its results. Measures one complete user
#       scroll gesture and its exact CPU, memory, wakeup, and energy window.
#   snapshot
#       Print a one-shot CPU, RSS, thread, footprint, and network sample.
#   summarize <artifact-directory>
#       Produce a deterministic scenario-appropriate summary. Authenticated
#       scroll uses exact monotonic workload bounds for process counters;
#       startup uses signpost-bounded Time Profiler samples. Writes summary.txt
#       beside the raw capture. Activity Monitor's normalized Energy Impact
#       number is private and is not the same measurement as top's power column.
#       For diagnostic captures made without physical input, set
#       SAKURACORD_PERFORMANCE_ALLOW_MISSING_GESTURES=1. The summary is then
#       explicitly labeled as lacking gesture coverage; strict mode is default.
#
# Artifacts are written beneath .build/performance and remain untracked.

running_pid() {
    local candidate actual
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        actual="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
        if is_scoped_command "$actual"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(pgrep -x SakuraCord || true)
    return 1
}

is_scoped_command() {
    local actual="$1"
    [[ "$actual" == "$executable" || "$actual" == "$executable "* ]]
}

require_running_pid() {
    local pid
    if ! pid="$(running_pid)"; then
        printf '%s\n' "The exact scoped SakuraCord app is not running: $app" >&2
        exit 3
    fi
    printf '%s\n' "$pid"
}

terminate_scoped_pid() {
    local pid="${1:-}" actual
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    actual="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if ! is_scoped_command "$actual"; then
        printf '%s\n' \
            "Refusing to terminate a process outside the exact benchmark scope: $pid" >&2
        return 1
    fi

    kill -TERM "$pid"
    for _ in {1..100}; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.02
    done

    # A benchmark process must never outlive its capture. Recheck the command
    # before escalating so a recycled PID cannot terminate an unrelated app.
    actual="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if ! is_scoped_command "$actual"; then
        printf '%s\n' \
            "Benchmark PID changed scope before forced termination: $pid" >&2
        return 1
    fi
    kill -KILL "$pid"
    for _ in {1..100}; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.02
    done
    printf '%s\n' "The scoped benchmark app did not terminate: $pid" >&2
    return 1
}

new_xctrace_scratch_directory() {
    local parent="$root/.build/performance-tools"
    if pgrep -x xctrace >/dev/null; then
        printf '%s\n' \
            'Another xctrace process is active; refusing an ambiguous benchmark capture.' >&2
        return 1
    fi
    mkdir -p "$parent"
    mktemp -d "$parent/xctrace-scratch.XXXXXX"
}

snapshot_xctrace_temporary_files() {
    local directory="$1" temporary_root="${TMPDIR:-/tmp}"
    temporary_root="${temporary_root%/}"
    find "$temporary_root" -mindepth 1 -maxdepth 1 -type f \
        -name 'instruments*.ktrace' -print \
        | LC_ALL=C sort >"$directory/temporary-files-before.txt"
}

cleanup_new_xctrace_temporary_files() {
    local directory="${1:-}" temporary_root="${TMPDIR:-/tmp}"
    local current candidate
    [[ -n "$directory" && -f "$directory/temporary-files-before.txt" ]] \
        || return 0
    if pgrep -x xctrace >/dev/null; then
        printf '%s\n' \
            'Leaving xctrace temporary files in place because another xctrace process is active.' >&2
        return 0
    fi
    temporary_root="${temporary_root%/}"
    current="$directory/temporary-files-after.txt"
    find "$temporary_root" -mindepth 1 -maxdepth 1 -type f \
        -name 'instruments*.ktrace' -print \
        | LC_ALL=C sort >"$current"
    comm -13 "$directory/temporary-files-before.txt" "$current" \
        | while IFS= read -r candidate; do
            case "$candidate" in
                "$temporary_root/"instruments*.ktrace) rm -f -- "$candidate" ;;
                *)
                    printf '%s\n' \
                        "Refusing to remove an unscoped xctrace temporary file: $candidate" >&2
                    return 1
                    ;;
            esac
        done
}

cleanup_xctrace_scratch_directory() {
    local directory="${1:-}"
    [[ -n "$directory" ]] || return 0
    case "$directory" in
        "$root/.build/performance-tools/"xctrace-scratch.*) ;;
        *)
            printf '%s\n' \
                "Refusing to remove an unscoped xctrace scratch directory: $directory" >&2
            return 1
            ;;
    esac
    [[ -d "$directory" ]] || return 0
    rm -rf "$directory"
}

terminate_xctrace_pid() {
    local pid="${1:-}" actual
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    actual="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$actual" != *'/xctrace record '* ]]; then
        printf '%s\n' \
            "Refusing to terminate a process outside xctrace record scope: $pid" >&2
        return 1
    fi
    kill -TERM "$pid" 2>/dev/null || true
    for _ in {1..100}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.02
    done
    if kill -0 "$pid" 2>/dev/null; then
        actual="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        if [[ "$actual" != *'/xctrace record '* ]]; then
            printf '%s\n' \
                "xctrace PID changed scope before forced termination: $pid" >&2
            return 1
        fi
        kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
}

new_output_directory() {
    local scenario="$1" stamp output suffix
    stamp="$(date '+%Y%m%d-%H%M%S')"
    output="$root/.build/performance/$stamp-$scenario"
    suffix=1
    while [[ -e "$output" ]]; do
        output="$root/.build/performance/$stamp-$scenario-$suffix"
        suffix=$((suffix + 1))
    done
    printf '%s\n' "$output"
}

write_source_manifest() {
    local output="$1" tracked_diff_hash relative file_hash
    tracked_diff_hash="$(
        git -C "$source_root" diff --binary HEAD \
            | shasum -a 256 | awk '{print $1}'
    )"
    {
        printf 'tracked-diff\t%s\n' "$tracked_diff_hash"
        git -C "$source_root" ls-files --others --exclude-standard \
            | LC_ALL=C sort \
            | while IFS= read -r relative; do
                [[ -n "$relative" ]] || continue
                file_hash="$(
                    shasum -a 256 "$source_root/$relative" | awk '{print $1}'
                )"
                printf 'untracked\t%s\t%s\n' "$relative" "$file_hash"
            done
    } >"$output/source-manifest.tsv"
}

current_source_state_hash() {
    local temporary hash
    temporary="$(mktemp -d "${TMPDIR:-/tmp}/sakuracord-source-state.XXXXXX")"
    write_source_manifest "$temporary"
    hash="$(shasum -a 256 "$temporary/source-manifest.tsv" | awk '{print $1}')"
    rm -rf "$temporary"
    printf '%s\n' "$hash"
}

record_build_provenance() {
    if [[ ! -f "$executable" ]]; then
        printf '%s\n' "Cannot record build provenance; executable is missing: $executable" >&2
        exit 8
    fi
    local executable_hash source_state_hash destination temporary
    executable_hash="$(shasum -a 256 "$executable" | awk '{print $1}')"
    source_state_hash="$(current_source_state_hash)"
    destination="$provenance_directory/$executable_hash.tsv"
    temporary="$destination.tmp.$$"
    mkdir -p "$provenance_directory"
    {
        printf 'executable_sha256\t%s\n' "$executable_hash"
        printf 'source_state_sha256\t%s\n' "$source_state_hash"
        printf 'git_revision\t%s\n' "$(git -C "$source_root" rev-parse HEAD)"
    } >"$temporary"
    mv "$temporary" "$destination"
    printf '%s\n' "Recorded benchmark build provenance: $destination"
}

verify_build_provenance() {
    if [[ ! -f "$executable" ]]; then
        printf '%s\n' "Benchmark executable is missing: $executable" >&2
        exit 8
    fi
    local executable_hash source_state_hash provenance expected_source_state
    executable_hash="$(shasum -a 256 "$executable" | awk '{print $1}')"
    provenance="$provenance_directory/$executable_hash.tsv"
    if [[ ! -f "$provenance" ]]; then
        printf '%s\n' \
            "No source provenance exists for this executable. Run performance_benchmark.sh build first." >&2
        exit 8
    fi
    expected_source_state="$(
        awk -F '\t' '$1 == "source_state_sha256" { print $2 }' "$provenance"
    )"
    source_state_hash="$(current_source_state_hash)"
    if [[ -z "$expected_source_state" || "$source_state_hash" != "$expected_source_state" ]]; then
        printf '%s\n' \
            "The benchmark source state changed after this executable was built. Rebuild before recording." >&2
        exit 8
    fi
    printf '%s\n' "$source_state_hash"
}

write_recording_metadata() {
    local output="$1" scenario="$2" template="$3"
    local performance_account_id="${4:-}"
    local build_source_state_hash
    build_source_state_hash="$(verify_build_provenance)"
    local executable_hash="unavailable"
    if [[ -f "$executable" ]]; then
        executable_hash="$(shasum -a 256 "$executable" | awk '{print $1}')"
    fi
    write_source_manifest "$output"
    local tracked_diff_hash source_state_hash
    tracked_diff_hash="$(
        awk -F '\t' '$1 == "tracked-diff" { print $2 }' \
            "$output/source-manifest.tsv"
    )"
    source_state_hash="$(
        shasum -a 256 "$output/source-manifest.tsv" | awk '{print $1}'
    )"
    if [[ "$source_state_hash" != "$build_source_state_hash" ]]; then
        printf '%s\n' \
            "The source state changed while benchmark metadata was being captured." >&2
        exit 8
    fi
    {
        printf 'scenario\t%s\n' "$scenario"
        printf 'template\t%s\n' "$template"
        printf 'recorded_at_utc\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'git_revision\t%s\n' "$(git -C "$source_root" rev-parse HEAD)"
        printf 'tracked_diff_sha256\t%s\n' "$tracked_diff_hash"
        printf 'source_state_sha256\t%s\n' "$source_state_hash"
        printf 'build_source_state_sha256\t%s\n' "$build_source_state_hash"
        printf 'executable_sha256\t%s\n' "$executable_hash"
        if [[ -n "$performance_account_id" ]]; then
            printf 'performance_account_id\t%s\n' "$performance_account_id"
        fi
        printf 'app\t%s\n' "$app"
        printf 'macos\t%s\n' "$(sw_vers -productVersion)"
        printf 'build\t%s\n' "$(sw_vers -buildVersion)"
        printf 'hardware\t%s\n' "$(sysctl -n hw.model)"
        printf 'architecture\t%s\n' "$(uname -m)"
    } >"$output/metadata.tsv"
    git -C "$source_root" status --porcelain=v1 >"$output/working-tree.txt"
}

wait_for_trace_start() {
    local notify_pid="$1" trace_pid="$2" output="$3" trace_status
    for _ in {1..300}; do
        if ! kill -0 "$notify_pid" 2>/dev/null; then
            wait "$notify_pid"
            return 0
        fi
        if ! kill -0 "$trace_pid" 2>/dev/null; then
            trace_status=0
            wait "$trace_pid" || trace_status=$?
            kill -TERM "$notify_pid" 2>/dev/null || true
            wait "$notify_pid" 2>/dev/null || true
            printf '%s\n' \
                "xctrace exited before tracing started (status $trace_status)." \
                >"$output/trace-start-error.txt"
            return 7
        fi
        sleep 0.05
    done
    kill -TERM "$notify_pid" "$trace_pid" 2>/dev/null || true
    wait "$notify_pid" 2>/dev/null || true
    wait "$trace_pid" 2>/dev/null || true
    printf '%s\n' "Timed out waiting for xctrace to start." \
        >"$output/trace-start-error.txt"
    return 7
}

export_trace_tables() {
    local trace="$1" output="$2"
    xcrun xctrace export \
        --input "$trace" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]' \
        --output "$output/signposts.xml" >/dev/null 2>&1 || true
    xcrun xctrace export \
        --input "$trace" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
        --output "$output/time-profile.xml" >/dev/null 2>&1 || true
    xcrun xctrace export \
        --input "$trace" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="activity-monitor-process-live"]' \
        --output "$output/activity-monitor-process.xml" >/dev/null 2>&1 || true
    xcrun xctrace export \
        --input "$trace" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="activity-monitor-process-ledger"]' \
        --output "$output/activity-monitor-ledger.xml" >/dev/null 2>&1 || true
}

ensure_rusage_sampler() {
    local tool_dir="$root/.build/performance-tools"
    local sampler="$tool_dir/performance-rusage"
    mkdir -p "$tool_dir"
    if [[ ! -x "$sampler" \
          || "$root/script/performance_rusage.c" -nt "$sampler" ]]; then
        xcrun clang -O2 -Wall -Wextra -Werror \
            "$root/script/performance_rusage.c" \
            -o "$sampler"
    fi
    printf '%s\n' "$sampler"
}

record_running_app() (
    local scenario="$1" seconds="$2" template="$3" pid output trace samples sampler
    local notification notify_pid trace_pid top_pid energy_pid nettop_pid
    local trace_scratch_directory trace_status sampler_duration
    trap 'terminate_xctrace_pid "${trace_pid:-}" >/dev/null 2>&1 || true; cleanup_new_xctrace_temporary_files "${trace_scratch_directory:-}" >/dev/null 2>&1 || true; cleanup_xctrace_scratch_directory "${trace_scratch_directory:-}" >/dev/null 2>&1 || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    pid="$(require_running_pid)"
    if [[ "$template" == "Power Profiler" ]]; then
        printf '%s\n' \
            "Power Profiler is iOS/iPadOS-only. Use the Activity Monitor template on macOS." >&2
        exit 5
    fi
    output="$(new_output_directory "$scenario")"
    trace="$output/recording.trace"
    samples="$seconds"
    mkdir -p "$output"
    write_recording_metadata "$output" "$scenario" "$template"
    printf '%s\n' \
        "Preparing $scenario for ${seconds}s with $template." \
        "Output: $output"

    notification="dev.sakuracord.performance.trace-started.$$.${RANDOM}"
    trace_scratch_directory="$(new_xctrace_scratch_directory)"
    snapshot_xctrace_temporary_files "$trace_scratch_directory"
    notifyutil -1 "$notification" >"$output/trace-start-notification.txt" &
    notify_pid=$!
    TMPDIR="$trace_scratch_directory/" xcrun xctrace record \
        --template "$template" \
        --time-limit "${seconds}s" \
        --no-prompt \
        --notify-tracing-started "$notification" \
        --output "$trace" \
        --attach "$pid" &
    trace_pid=$!
    wait_for_trace_start "$notify_pid" "$trace_pid" "$output"
    top -pid "$pid" -l "$samples" -s 1 \
        -stats pid,cpu,mem,threads,power -o cpu >"$output/activity-monitor.txt" &
    top_pid=$!
    sampler="$(ensure_rusage_sampler)"
    sampler_duration="$(awk -v duration="$seconds" 'BEGIN { print duration + 1 }')"
    "$sampler" "$pid" "$sampler_duration" 250 >"$output/rusage-energy.csv" \
        2>"$output/rusage-energy-error.txt" &
    energy_pid=$!
    nettop -P -p "$pid" -L "$samples" -s 1 -x -n \
        >"$output/network.csv" 2>"$output/network-error.txt" &
    nettop_pid=$!
    touch "$output/interaction-ready"
    printf '%s\n' \
        "Recording active: $scenario." \
        "Use SakuraCord normally now; do not send messages or mutate account data."
    trace_status=0
    wait "$trace_pid" || trace_status=$?
    trace_pid=""
    (( trace_status == 0 )) || exit "$trace_status"
    wait "$top_pid" || true
    wait "$energy_pid" || true
    wait "$nettop_pid" || true
    export_trace_tables "$trace" "$output"
    cleanup_new_xctrace_temporary_files "$trace_scratch_directory"
    cleanup_xctrace_scratch_directory "$trace_scratch_directory"
    trace_scratch_directory=""
    footprint "$pid" >"$output/footprint.txt" 2>"$output/footprint-error.txt" || true
    printf '%s\n' "Completed: $output"
)

record_launch() (
    local scenario="$1" seconds="$2" pid output trace trace_pid notify_pid notification sampler
    local stopped_state sandbox_directory sandbox_result sandbox_window
    local performance_account_id debug_credential_directory newest_credential
    local preferred_account_id
    local resource_window_name scroll_input_telemetry scroll_surface
    local requires_interactive_window
    local trace_scratch_directory trace_status sampler_duration
    shift 2
    trap 'terminate_xctrace_pid "${trace_pid:-}" >/dev/null 2>&1 || true; cleanup_new_xctrace_temporary_files "${trace_scratch_directory:-}" >/dev/null 2>&1 || true; cleanup_xctrace_scratch_directory "${trace_scratch_directory:-}" >/dev/null 2>&1 || true; terminate_scoped_pid "${pid:-}" >/dev/null 2>&1 || true' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    pid="$(running_pid || true)"
    if [[ -n "$pid" ]]; then
        if ! is_scoped_command "$(ps -p "$pid" -o command=)"; then
            printf '%s\n' "Refusing to stop an unscoped process." >&2
            exit 4
        fi
        kill -TERM "$pid"
        for _ in {1..100}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.02
        done
        if kill -0 "$pid" 2>/dev/null; then
            printf '%s\n' "The scoped app did not terminate: $pid" >&2
            exit 4
        fi
        if pid="$(running_pid || true)"; [[ -n "$pid" ]]; then
            printf '%s\n' \
                "Another scoped SakuraCord process is still running: $pid" >&2
            exit 4
        fi
    fi

    output="$(new_output_directory "$scenario")"
    trace="$output/recording.trace"
    notification="dev.sakuracord.performance.trace-started.$$.${RANDOM}"
    mkdir -p "$output"
    case "$scenario" in
        authenticated-scroll) resource_window_name="MessageTimelineAutoScrollBenchmark" ;;
        authenticated-member-list-scroll) resource_window_name="MemberListAutoScrollBenchmark" ;;
        authenticated-gesture-scroll) resource_window_name="AuthenticatedGestureScrollBenchmark" ;;
        authenticated-loading-scroll-overlap) resource_window_name="AuthenticatedLoadingScrollOverlapBenchmark" ;;
        authenticated-navigation) resource_window_name="AuthenticatedNavigationBenchmark" ;;
        authenticated-account-switch) resource_window_name="AuthenticatedAccountSwitchBenchmark" ;;
        authenticated-history-pagination) resource_window_name="AuthenticatedHistoryPaginationBenchmark" ;;
        authenticated-search) resource_window_name="MessageSearchBenchmark" ;;
        authenticated-search-pagination) resource_window_name="MessageSearchPaginationBenchmark" ;;
        authenticated-search-scroll) resource_window_name="MessageSearchScrollBenchmark" ;;
        *) resource_window_name="" ;;
    esac
    if [[ "$scenario" == "authenticated-member-list-scroll" \
          || "$scenario" == "authenticated-gesture-scroll" \
          || "$scenario" == "authenticated-loading-scroll-overlap" ]]; then
        requires_interactive_window=1
        if [[ "$scenario" == "authenticated-member-list-scroll" ]]; then
            scroll_input_telemetry=0
        else
            scroll_input_telemetry=1
        fi
    else
        scroll_input_telemetry=0
        requires_interactive_window=0
    fi
    scroll_surface="${SAKURACORD_PERFORMANCE_SCROLL_SURFACE:-all}"
    performance_account_id="${SAKURACORD_PERFORMANCE_ACCOUNT_ID:-}"
    if [[ "$scenario" == "authenticated-scroll" \
          || "$scenario" == "authenticated-member-list-scroll" \
          || "$scenario" == "authenticated-gesture-scroll" \
          || "$scenario" == "authenticated-loading-scroll-overlap" \
          || "$scenario" == "authenticated-navigation" \
          || "$scenario" == "authenticated-account-switch" \
          || "$scenario" == "authenticated-history-pagination" \
          || "$scenario" == "authenticated-search" \
          || "$scenario" == "authenticated-search-pagination" \
          || "$scenario" == "authenticated-search-scroll" ]]; then
        debug_credential_directory="$HOME/Library/Containers/$bundle_id/Data/Library/Application Support/SakuraCord/InsecureDebugCredentials"
        if [[ -z "$performance_account_id" ]]; then
            preferred_account_id="$(
                defaults read "$bundle_id" \
                    'dev.sakuracord.preferred-account-id' 2>/dev/null || true
            )"
            if [[ "$preferred_account_id" =~ ^[0-9]+$ ]] \
                && [[ -f "$debug_credential_directory/$preferred_account_id.credential" ]]
            then
                performance_account_id="$preferred_account_id"
            else
                newest_credential="$(
                    find "$debug_credential_directory" -maxdepth 1 -type f \
                        -name '*.credential' -print 2>/dev/null \
                        | while IFS= read -r candidate; do
                            printf '%s\t%s\n' "$(stat -f '%m' "$candidate")" "$candidate"
                        done \
                        | sort -rn | head -1 | cut -f2-
                )"
                performance_account_id="$(
                    basename "$newest_credential" .credential 2>/dev/null || true
                )"
            fi
        fi
        if [[ ! "$performance_account_id" =~ ^[0-9]+$ ]] \
            || [[ ! -f "$debug_credential_directory/$performance_account_id.credential" ]]
        then
            printf '%s\n' \
                "Authenticated performance recording requires a selected local debug credential." >&2
            exit 4
        fi
        if [[ "$scenario" == "authenticated-account-switch" ]]; then
            credential_count="$((
                $(find "$debug_credential_directory" -maxdepth 1 -type f \
                    -name '*.credential' -print 2>/dev/null | wc -l)
            ))"
            if (( credential_count < 2 )); then
                printf '%s\n' \
                    "Authenticated account-switch recording requires at least two local debug credentials." >&2
                exit 4
            fi
        fi
    fi
    write_recording_metadata \
        "$output" "$scenario" "Time Profiler" "$performance_account_id"
    sandbox_directory="$HOME/Library/Containers/$bundle_id/Data/tmp"
    mkdir -p "$sandbox_directory"
    sandbox_result="$(mktemp "$sandbox_directory/sakuracord-performance-result.XXXXXX")"
    sandbox_window="$(mktemp "$sandbox_directory/sakuracord-performance-window.XXXXXX")"
    if (( requires_interactive_window )); then
        # Computer Use resolves windows through LaunchServices. A raw executable
        # launch is profileable but exposes no operable app window, so scenarios
        # that require manual surface selection or physical input launch the exact
        # canonical bundle and suspend its sole process as soon as LaunchServices
        # publishes its PID. Their
        # measured windows begin only after authenticated workspace setup, well
        # after this bounded pre-attach launch interval.
        open -n \
            -i /dev/null \
            -o "$output/app-stdout.log" \
            --stderr "$output/app-output.log" \
            --env SAKURACORD_INSECURE_DEBUG_CREDENTIALS=1 \
            --env "SAKURACORD_PERFORMANCE_ACCOUNT_ID=$performance_account_id" \
            --env "SAKURACORD_PERFORMANCE_WINDOW_NAME=$resource_window_name" \
            --env "SAKURACORD_PERFORMANCE_WINDOW_PATH=$sandbox_window" \
            --env "SAKURACORD_PERFORMANCE_RESULT_PATH=$sandbox_result" \
            --env "SAKURACORD_SCROLL_INPUT_TELEMETRY=$scroll_input_telemetry" \
            --env "SAKURACORD_PERFORMANCE_SCROLL_SURFACE=$scroll_surface" \
            "$app" \
            --args "$@"
        pid=""
        for _ in {1..300}; do
            pid="$(running_pid || true)"
            [[ -n "$pid" ]] && break
            sleep 0.02
        done
        if [[ -z "$pid" ]]; then
            printf '%s\n' \
                "LaunchServices did not publish the scoped benchmark process." >&2
            exit 4
        fi
        kill -STOP "$pid"
    else
        # xctrace's direct --launch path can leave a never-executed process stub
        # on current macOS/Xcode beta builds. Start a suspended wrapper instead,
        # attach the trace to its stable PID, and only exec the app once tracing
        # is active. The exec preserves the PID so startup and benchmark
        # signposts remain in one process trace.
        SAKURACORD_INSECURE_DEBUG_CREDENTIALS=1 \
            SAKURACORD_PERFORMANCE_ACCOUNT_ID="$performance_account_id" \
            SAKURACORD_PERFORMANCE_WINDOW_NAME="$resource_window_name" \
            SAKURACORD_PERFORMANCE_WINDOW_PATH="$sandbox_window" \
            SAKURACORD_PERFORMANCE_RESULT_PATH="$sandbox_result" \
            SAKURACORD_SCROLL_INPUT_TELEMETRY="$scroll_input_telemetry" \
            SAKURACORD_PERFORMANCE_SCROLL_SURFACE="$scroll_surface" \
            /bin/sh -c 'kill -STOP "$$"; exec "$@"' sh "$executable" "$@" \
            >"$output/app-output.log" 2>&1 &
        pid=$!
    fi
    printf '%s\n' "$pid" >"$output/app-pid.txt"
    stopped_state=""
    for _ in {1..100}; do
        stopped_state="$(ps -p "$pid" -o state= 2>/dev/null || true)"
        [[ "$stopped_state" == *T* ]] && break
        sleep 0.02
    done
    if [[ "$stopped_state" != *T* ]]; then
        printf '%s\n' "Benchmark launch wrapper did not suspend: $pid" >&2
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        exit 4
    fi

    notifyutil -1 "$notification" >"$output/trace-start-notification.txt" &
    notify_pid=$!
    trace_scratch_directory="$(new_xctrace_scratch_directory)"
    snapshot_xctrace_temporary_files "$trace_scratch_directory"
    TMPDIR="$trace_scratch_directory/" xcrun xctrace record \
        --template 'Time Profiler' \
        --time-limit "${seconds}s" \
        --no-prompt \
        --notify-tracing-started "$notification" \
        --output "$trace" \
        --attach "$pid" &
    trace_pid=$!
    if ! wait_for_trace_start "$notify_pid" "$trace_pid" "$output"; then
        kill -CONT "$pid" 2>/dev/null || true
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        exit 7
    fi
    if (( ! requires_interactive_window )); then
        # The tracing-started notification can precede completion of the
        # attach-side process subscription by a fraction of a second. Keep the
        # wrapper suspended until that subscription settles; otherwise the app
        # can emit its first startup signpost after exec but before Instruments
        # has begun collecting the replacement image for the preserved PID.
        sleep 0.25
    fi
    kill -CONT "$pid"
    if [[ ( "$scenario" == "authenticated-scroll" \
            || "$scenario" == "authenticated-member-list-scroll" \
            || "$scenario" == "authenticated-gesture-scroll" \
            || "$scenario" == "authenticated-loading-scroll-overlap" \
            || "$scenario" == "authenticated-navigation" \
            || "$scenario" == "authenticated-account-switch" \
            || "$scenario" == "authenticated-history-pagination" \
            || "$scenario" == "authenticated-search" \
            || "$scenario" == "authenticated-search-pagination" \
            || "$scenario" == "authenticated-search-scroll" ) \
          && -n "$pid" ]]; then
        top -pid "$pid" -l "$seconds" -s 1 \
            -stats pid,cpu,mem,threads,power -o cpu \
            >"$output/activity-monitor.txt" &
        local top_pid=$!
        sampler="$(ensure_rusage_sampler)"
        sampler_duration="$(awk -v duration="$seconds" 'BEGIN { print duration + 1 }')"
        "$sampler" "$pid" "$sampler_duration" 250 \
            >"$output/rusage-energy.csv" \
            2>"$output/rusage-energy-error.txt" &
        local energy_pid=$!
        nettop -P -p "$pid" -L "$seconds" -s 1 -x -n \
            >"$output/network.csv" 2>"$output/network-error.txt" &
        local nettop_pid=$!
    fi
    trace_status=0
    wait "$trace_pid" || trace_status=$?
    trace_pid=""
    (( trace_status == 0 )) || exit "$trace_status"
    if [[ ( "$scenario" == "authenticated-scroll" \
            || "$scenario" == "authenticated-member-list-scroll" \
            || "$scenario" == "authenticated-gesture-scroll" \
            || "$scenario" == "authenticated-loading-scroll-overlap" \
            || "$scenario" == "authenticated-navigation" \
            || "$scenario" == "authenticated-account-switch" \
            || "$scenario" == "authenticated-history-pagination" \
            || "$scenario" == "authenticated-search" \
            || "$scenario" == "authenticated-search-pagination" \
            || "$scenario" == "authenticated-search-scroll" ) \
          && -n "$pid" ]]; then
        wait "$top_pid" || true
        wait "$energy_pid" || true
        wait "$nettop_pid" || true
        footprint "$pid" >"$output/footprint.txt" \
            2>"$output/footprint-error.txt" || true
    fi
    if [[ -s "$sandbox_result" ]]; then
        mv "$sandbox_result" "$output/benchmark-result.tsv"
    else
        rm -f "$sandbox_result"
    fi
    if [[ -s "$sandbox_window" ]]; then
        mv "$sandbox_window" "$output/resource-window.tsv"
    else
        rm -f "$sandbox_window"
    fi
    export_trace_tables "$trace" "$output"
    if [[ "$scenario" != "startup" \
          && ( ! -s "$output/benchmark-result.tsv" \
               || ! -s "$output/resource-window.tsv" ) ]]; then
        printf '%s\n' \
            "Benchmark did not publish its required result and resource window: $scenario" >&2
        exit 6
    fi
    cleanup_new_xctrace_temporary_files "$trace_scratch_directory"
    cleanup_xctrace_scratch_directory "$trace_scratch_directory"
    trace_scratch_directory=""
    terminate_scoped_pid "$pid"
    pid=""
    printf '%s\n' "Completed: $output"
)

record_startup() {
    record_launch startup "$1"
}

record_authenticated_scroll() {
    record_launch authenticated-scroll "$1" \
        --debug-authenticated-chat-performance-autoscroll
}

record_authenticated_member_list_scroll() {
    record_launch authenticated-member-list-scroll "$1" \
        --debug-authenticated-member-list-performance-autoscroll
}

record_authenticated_gesture_scroll() {
    record_launch authenticated-gesture-scroll "$1" \
        --debug-authenticated-gesture-scroll-performance
}

record_authenticated_loading_scroll_overlap() {
    local seconds="$1" surface="$2"
    case "$surface" in
        timeline|member-list|channel-list|server-list) ;;
        *)
            printf '%s\n' \
                'Loading-scroll surface must be timeline, member-list, channel-list, or server-list.' >&2
            exit 2
            ;;
    esac
    SAKURACORD_PERFORMANCE_SCROLL_SURFACE="$surface" \
        record_launch authenticated-loading-scroll-overlap "$seconds" \
        --debug-authenticated-loading-scroll-overlap-performance
}

record_authenticated_navigation() {
    record_launch authenticated-navigation "$1" \
        --debug-authenticated-navigation-performance
}

record_authenticated_account_switch() {
    record_launch authenticated-account-switch "$1" \
        --debug-authenticated-account-switch-performance
}

record_authenticated_history_pagination() {
    record_launch authenticated-history-pagination "$1" \
        --debug-authenticated-history-pagination-performance
}

record_authenticated_search() {
    record_launch authenticated-search "$1"
}

record_authenticated_search_pagination() {
    record_launch authenticated-search-pagination "$1"
}

record_authenticated_search_scroll() {
    record_launch authenticated-search-scroll "$1"
}

summarize_recording() {
    local output="$1"
    if [[ ! -d "$output" ]]; then
        printf '%s\n' "Benchmark artifact directory does not exist: $output" >&2
        exit 6
    fi
    local scenario profile_process profile_interval allow_missing_gestures
    allow_missing_gestures="${SAKURACORD_PERFORMANCE_ALLOW_MISSING_GESTURES:-0}"
    scenario="$(
        awk -F '\t' '$1 == "scenario" { print $2 }' "$output/metadata.tsv"
    )"
    case "$scenario" in
        authenticated-scroll)
            profile_interval="MessageTimelineAutoScrollBenchmark"
            ;;
        authenticated-member-list-scroll)
            profile_interval="MemberListAutoScrollBenchmark"
            ;;
        authenticated-gesture-scroll)
            profile_interval="AuthenticatedGestureScrollBenchmark"
            ;;
        authenticated-loading-scroll-overlap)
            profile_interval="AuthenticatedLoadingScrollOverlapBenchmark"
            ;;
        authenticated-navigation)
            profile_interval="AuthenticatedNavigationBenchmark"
            ;;
        authenticated-account-switch)
            profile_interval="AuthenticatedAccountSwitchBenchmark"
            ;;
        authenticated-history-pagination)
            profile_interval="AuthenticatedHistoryPaginationBenchmark"
            ;;
        authenticated-search)
            profile_interval="MessageSearchRequestToResults"
            ;;
        authenticated-search-pagination)
            profile_interval="MessageSearchPaginationToResults"
            ;;
        authenticated-search-scroll)
            profile_interval="MessageSearchUserScroll"
            ;;
        *) profile_interval="" ;;
    esac
    if [[ -n "$profile_interval" \
          && -s "$output/time-profile.xml" ]]; then
        if [[ ! -s "$output/time-profile.xml" \
              || ! -s "$output/signposts.xml" \
              || ! -s "$output/app-pid.txt" ]]; then
            printf '%s\n' \
                "Authenticated artifacts require non-empty Time Profiler, signpost, and app PID data." >&2
            exit 6
        fi
        profile_process="$(tr -d '[:space:]' <"$output/app-pid.txt")"
        if [[ ! "$profile_process" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "Authenticated artifact has an invalid app PID." >&2
            exit 6
        fi
        python3 "$root/script/time_profile_hotspots.py" \
            "$output/time-profile.xml" \
            --process "$profile_process" \
            --signposts "$output/signposts.xml" \
            --interval "$profile_interval" \
            --limit 50 \
            >"$output/measurement-time-profile.txt"
        python3 "$root/script/time_profile_hotspots.py" \
            "$output/time-profile.xml" \
            --process "$profile_process" \
            --signposts "$output/signposts.xml" \
            --interval "$profile_interval" \
            --contains 'OutlineListCoordinator' \
            --app-only \
            --limit 50 \
            >"$output/measurement-outline-list-time-profile.txt"
        if [[ ( "$scenario" == "authenticated-scroll" \
                || "$scenario" == "authenticated-member-list-scroll" ) \
              && -s "$output/benchmark-result.tsv" \
              && -n "$(awk -F '\t' '$1 == "delayed_tick_samples_offset_ms_interval_ms" { print $2 }' "$output/benchmark-result.tsv")" ]]; then
            python3 "$root/script/time_profile_hotspots.py" \
                "$output/time-profile.xml" \
                --process "$profile_process" \
                --signposts "$output/signposts.xml" \
                --interval "$profile_interval" \
                --delayed-ticks "$output/benchmark-result.tsv" \
                --limit 50 \
                >"$output/delayed-frame-time-profile.txt"
        fi
        if [[ ! -s "$output/measurement-time-profile.txt" \
              || ! -s "$output/measurement-outline-list-time-profile.txt" ]]; then
            printf '%s\n' "Authenticated Time Profiler summary is empty." >&2
            exit 6
        fi
    fi
    if [[ "$scenario" == "startup" ]]; then
        if [[ ! -s "$output/time-profile.xml" \
              || ! -s "$output/signposts.xml" \
              || ! -s "$output/app-pid.txt" ]]; then
            printf '%s\n' \
                "Startup artifacts require non-empty Time Profiler, signpost, and app PID data." >&2
            exit 6
        fi
        profile_process="$(tr -d '[:space:]' <"$output/app-pid.txt")"
        if [[ ! "$profile_process" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "Startup artifact has an invalid app PID." >&2
            exit 6
        fi
        python3 "$root/script/time_profile_hotspots.py" \
            "$output/time-profile.xml" \
            --process "$profile_process" \
            --signposts "$output/signposts.xml" \
            --interval StartupToWorkspace \
            --app-only \
            >"$output/startup-time-profile.txt"
        if [[ ! -s "$output/startup-time-profile.txt" ]]; then
            printf '%s\n' "Startup Time Profiler summary is empty." >&2
            exit 6
        fi
    fi
    /usr/bin/ruby -r csv -r rexml/document - \
        "$output" "$allow_missing_gestures" <<'RUBY' \
        | tee "$output/summary.txt"
directory = File.expand_path(ARGV.fetch(0))
allows_missing_gestures = ARGV.fetch(1, "0") == "1"

def percentile(values, fraction)
  return nil if values.empty?
  sorted = values.sort
  sorted[[(sorted.length * fraction).ceil - 1, 0].max]
end

def format_metric(value, unit)
  value ? format("%.3f %s", value, unit) : "unavailable"
end

def overlapping_interval_union_duration(bounds, lower_bound, upper_bound)
  clipped = bounds.each_with_object([]) do |(start_at, end_at), result|
    start_at = [start_at, lower_bound].max
    end_at = [end_at, upper_bound].min
    result << [start_at, end_at] if end_at > start_at
  end.sort_by(&:first)
  return 0.0 if clipped.empty?
  total = 0.0
  current_start, current_end = clipped.first
  clipped.drop(1).each do |start_at, end_at|
    if start_at <= current_end
      current_end = [current_end, end_at].max
    else
      total += current_end - current_start
      current_start = start_at
      current_end = end_at
    end
  end
  total + current_end - current_start
end

def memory_bytes(value)
  match = value.to_s.match(/\A([0-9.]+)([KMGTP]?)B?[+\-]?\z/)
  return nil unless match
  scale = { "" => 1, "K" => 1_024, "M" => 1_024**2,
            "G" => 1_024**3, "T" => 1_024**4,
            "P" => 1_024**5 }.fetch(match[2])
  match[1].to_f * scale
end

cpu = []
cpu_average = nil
top_power_proxy = []
rss = []
sampled_physical_footprint = []
top_path = File.join(directory, "activity-monitor.txt")
if File.file?(top_path)
  File.foreach(top_path) do |line|
    fields = line.split
    next unless fields.length >= 5 && fields[0].match?(/\A\d+\z/)
    next unless fields[1].match?(/\A[0-9.]+\z/)
    cpu << fields[1].to_f
    rss_value = memory_bytes(fields[2])
    rss << rss_value if rss_value
    top_power_proxy << fields[4].to_f if fields[4].match?(/\A[0-9.]+\z/)
  end
end

energy_rates_mw = []
energy_average_mw = nil
energy_total_mj = nil
idle_wakeups_per_second = nil
interrupt_wakeups_per_second = nil
rusage_samples = []
energy_path = File.join(directory, "rusage-energy.csv")
if File.file?(energy_path)
  rusage_samples = CSV.read(energy_path, headers: true).map do |row|
    {
      monotonic: row["monotonic_ns"]&.to_i,
      elapsed: row["elapsed_ns"]&.to_i,
      energy: row["energy_nj"]&.to_i,
      user: row["user_time_ns"]&.to_i,
      system: row["system_time_ns"]&.to_i,
      idle: row["idle_wakeups"]&.to_i,
      interrupt: row["interrupt_wakeups"]&.to_i,
      footprint: row["phys_footprint_bytes"]&.to_i,
    }
  end.select do |sample|
    sample.values_at(
      :elapsed,
      :energy,
      :user,
      :system,
      :idle,
      :interrupt,
      :footprint
    ).none?(&:nil?)
  end
  rusage_samples.each_cons(2) do |before, after|
    elapsed = after[:elapsed] - before[:elapsed]
    energy = after[:energy] - before[:energy]
    next unless elapsed.positive? && energy >= 0
    energy_rates_mw << energy.to_f / elapsed * 1_000.0
  end
  if rusage_samples.length >= 2
    first = rusage_samples.first
    last = rusage_samples.last
    elapsed_seconds = (last[:elapsed] - first[:elapsed]).to_f / 1_000_000_000.0
    if elapsed_seconds.positive?
      energy_total_mj = (last[:energy] - first[:energy]).to_f / 1_000_000.0
      idle_wakeups_per_second =
        (last[:idle] - first[:idle]).to_f / elapsed_seconds
      interrupt_wakeups_per_second =
        (last[:interrupt] - first[:interrupt]).to_f / elapsed_seconds
    end
  end
end

network_in = []
network_out = []
network_path = File.join(directory, "network.csv")
if File.file?(network_path)
  CSV.foreach(network_path, headers: false) do |row|
    next if row[0] == "time" || row.length < 6
    network_in << row[4].to_i if row[4]&.match?(/\A\d+\z/)
    network_out << row[5].to_i if row[5]&.match?(/\A\d+\z/)
  end
end

footprint = nil
footprint_peak = nil
footprint_path = File.join(directory, "footprint.txt")
if File.file?(footprint_path)
  text = File.read(footprint_path)
  footprint = memory_bytes(
    text[/phys_footprint:\s+([0-9.]+\s*[KMGTP]?B)/, 1]&.delete(" ")
  )
  footprint_peak = memory_bytes(
    text[/phys_footprint_peak:\s+([0-9.]+\s*[KMGTP]?B)/, 1]&.delete(" ")
  )
end

scenario = nil
metadata_path = File.join(directory, "metadata.tsv")
if File.file?(metadata_path)
  File.foreach(metadata_path) do |line|
    key, value = line.chomp.split("\t", 2)
    scenario = value if key == "scenario"
  end
end
startup_pid_path = File.join(directory, "app-pid.txt")
startup_pid = File.file?(startup_pid_path) ? File.read(startup_pid_path).strip : nil

intervals = Hash.new { |hash, name| hash[name] = [] }
interval_bounds = Hash.new { |hash, name| hash[name] = [] }
event_counts = Hash.new(0)
event_bounds = Hash.new { |hash, name| hash[name] = [] }
unmatched_signposts = Hash.new(0)
signpost_path = File.join(directory, "signposts.xml")
if File.file?(signpost_path) && File.size?(signpost_path)
  document = REXML::Document.new(File.read(signpost_path))
  display_references = {}
  raw_references = {}
  seen = {}
  starts = Hash.new { |hash, key| hash[key] = [] }
  parse_milliseconds = lambda do |formatted|
    parts = formatted.to_s.scan(/\d+/).map(&:to_i)
    next nil unless parts.length >= 4
    (parts[0] * 60 + parts[1]) * 1_000 + parts[2] + parts[3] / 1_000.0
  end
  document.elements.each("//row") do |row|
    display_values = {}
    raw_values = {}
    row.elements.each do |element|
      display = element.attributes["fmt"] || element.text.to_s
      raw = element.text.to_s.empty? ? display : element.text.to_s
      if (identifier = element.attributes["id"])
        display_references[[element.name, identifier]] = display
        raw_references[[element.name, identifier]] = raw
      end
      if (reference = element.attributes["ref"])
        display_values[element.name] =
          display_references[[element.name, reference]]
        raw_values[element.name] = raw_references[[element.name, reference]]
      else
        display_values[element.name] = display
        raw_values[element.name] = raw
      end
    end
    name = display_values["signpost-name"]
    type = display_values["event-type"]
    formatted_time = display_values["event-time"]
    next unless name && type && formatted_time
    process = display_values["process"]
    unless process
      thread = display_values["thread"]
      # Async intervals routinely resume on another cooperative-pool thread.
      # xctrace places the only process definition inside the first thread
      # element, so later `<process ref>` values can be unresolved by this
      # streaming reference reader. Pair by the stable PID embedded in the
      # thread display name instead of falsely treating a thread migration as
      # two unmatched signposts.
      pid = thread&.match(/\bpid:\s*(\d+)\b/)&.[](1)
      process = pid ? "pid:#{pid}" : (thread || "unknown")
    end
    if scenario == "startup" && name == "StartupToWorkspace" &&
       startup_pid && !process.match?(/\b#{Regexp.escape(startup_pid)}\b/)
      next
    end
    signpost_id = raw_values["os-signpost-identifier"] || "missing"
    raw_time = raw_values["event-time"]
    identity = [raw_time, type, name, process, signpost_id]
    next if seen[identity]
    seen[identity] = true
    nanoseconds = raw_time&.match?(/\A\d+\z/) ? raw_time.to_i : nil
    milliseconds = nanoseconds ? nanoseconds / 1_000_000.0 :
      parse_milliseconds.call(formatted_time)
    next unless milliseconds
    key = [process, signpost_id, name]
    if type == "Begin"
      starts[key] << milliseconds
    elsif type == "End"
      if starts[key].empty?
        unmatched_signposts[name] += 1
      else
        started_at = starts[key].shift
        duration = milliseconds - started_at
        if duration >= 0
          intervals[name] << duration
          interval_bounds[name] << [started_at, milliseconds]
        end
      end
    elsif type == "Event"
      event_counts[name] += 1
      event_bounds[name] << milliseconds
    end
  end
  starts.each do |key, values|
    unmatched_signposts[key.last] += values.length
  end
end

main_thread_samples = []
time_profile_path = File.join(directory, "time-profile.xml")
if File.file?(time_profile_path) && File.size?(time_profile_path)
  document = REXML::Document.new(File.read(time_profile_path))
  display_references = {}
  raw_references = {}
  seen_samples = {}
  document.elements.each("//row") do |row|
    display_values = {}
    raw_values = {}
    row.elements.each do |element|
      display = element.attributes["fmt"] || element.text.to_s
      raw = element.text.to_s.empty? ? display : element.text.to_s
      if (identifier = element.attributes["id"])
        display_references[[element.name, identifier]] = display
        raw_references[[element.name, identifier]] = raw
      end
      if (reference = element.attributes["ref"])
        display_values[element.name] =
          display_references[[element.name, reference]]
        raw_values[element.name] = raw_references[[element.name, reference]]
      else
        display_values[element.name] = display
        raw_values[element.name] = raw
      end
    end
    thread = display_values["thread"]
    process = display_values["process"]
    next unless thread&.start_with?("Main Thread ")
    next unless display_values["thread-state"] == "Running"
    sample_pid = process&.match(/\b(\d+)\b/)&.[](1)
    sample_pid ||= thread.match(/\bpid:\s*(\d+)\b/)&.[](1)
    if startup_pid
      next unless sample_pid == startup_pid
    else
      next unless process&.include?("SakuraCord") || thread.include?("(SakuraCord,")
    end
    raw_time = raw_values["sample-time"]
    raw_weight = raw_values["weight"]
    next unless raw_time&.match?(/\A\d+\z/)
    next unless raw_weight&.match?(/\A\d+\z/)
    identity = [raw_time, raw_weight, thread]
    next if seen_samples[identity]
    seen_samples[identity] = true
    main_thread_samples << [
      raw_time.to_i / 1_000_000.0,
      raw_weight.to_i / 1_000_000.0,
    ]
  end
end

benchmark_result = {}
benchmark_result_path = File.join(directory, "benchmark-result.tsv")
if File.file?(benchmark_result_path)
  File.foreach(benchmark_result_path) do |line|
    key, value = line.chomp.split("\t", 2)
    benchmark_result[key] = value if key && value
  end
end
time_profile_sampled_milliseconds = lambda do |filename|
  path = File.join(directory, filename)
  next nil unless File.file?(path)
  sampled = File.foreach(path).find { |line| line.start_with?("sampled\t") }
  next nil unless sampled
  Float(sampled.split("\t", 2).last.strip.delete_suffix(" ms"), exception: false)
end
measurement_profile_sampled_ms = time_profile_sampled_milliseconds.call(
  "measurement-time-profile.txt"
)
outline_list_profile_sampled_ms = time_profile_sampled_milliseconds.call(
  "measurement-outline-list-time-profile.txt"
)
delayed_frame_profile_sampled_ms = time_profile_sampled_milliseconds.call(
  "delayed-frame-time-profile.txt"
)
scroll_benchmark = [
  "authenticated-scroll",
  "authenticated-member-list-scroll",
].include?(scenario)
navigation_benchmark = scenario == "authenticated-navigation"
account_switch_benchmark = scenario == "authenticated-account-switch"
history_pagination_benchmark = scenario == "authenticated-history-pagination"
scroll_interaction_benchmark = [
  "authenticated-gesture-scroll",
  "authenticated-loading-scroll-overlap",
].include?(scenario)
navigation_app_residuals = {}
navigation_history_network_subtracted_residuals = {}
navigation_history_network = {}
navigation_all_network_union = {}
navigation_other_rest_network_overlap = {}
navigation_outer_minus_all_network_union = {}
navigation_conversation_load_residuals = {}
navigation_outside_conversation_load_residuals = {}
navigation_first_frame_residuals = {}
navigation_outside_first_frame_residuals = {}
navigation_stage_durations = {}
navigation_stage_names = [
  "ConversationNavigationToFirstFrame",
  "ConversationLoad",
  "ConversationDraftLoad",
  "ConversationRowPreprocessing",
  "ConversationInitialCommit",
  "ConversationMemberResolution",
  "ConversationFinalize",
  "GuildActivation",
  "MemberSectionBuild",
  "MemberListDocumentPublication",
  "ChannelSidebarGrouping",
  "UnreadPresentationPublication",
  "ServerRailProjection",
  "TimelineCanvasDraw",
  "TimelineRowRaster",
  "TimelineSystemSymbolConfiguredPrewarm",
  "TimelineVisibleStaticMediaDecode",
  "TimelinePrefetchStaticMediaDecode",
  "CustomEmojiCatalogPreparation",
  "CustomEmojiCatalogPublication",
]
navigation_animation_decode_overlap_count = 0
navigation_animation_decode_overlap_ms = 0.0
navigation_animation_decode_overlap_maximum_ms = 0.0
navigation_static_decode_overlap_count = 0
navigation_static_decode_overlap_ms = 0.0
navigation_static_decode_overlap_maximum_ms = 0.0
loading_scroll_overlap_metrics = {}
measurement_interval = case scenario
                       when "authenticated-scroll"
                         "MessageTimelineAutoScrollBenchmark"
                       when "authenticated-member-list-scroll"
                         "MemberListAutoScrollBenchmark"
                       when "authenticated-gesture-scroll"
                         "AuthenticatedGestureScrollBenchmark"
                       when "authenticated-loading-scroll-overlap"
                         "AuthenticatedLoadingScrollOverlapBenchmark"
                       when "authenticated-navigation"
                         "AuthenticatedNavigationBenchmark"
                       when "authenticated-account-switch"
                         "AuthenticatedAccountSwitchBenchmark"
                       when "authenticated-history-pagination"
                         "AuthenticatedHistoryPaginationBenchmark"
                       when "authenticated-search"
                         "MessageSearchRequestToResults"
                       when "authenticated-search-pagination"
                         "MessageSearchPaginationToResults"
                       when "authenticated-search-scroll"
                         "MessageSearchUserScroll"
                       when "startup"
                         "StartupToWorkspace"
                       end
measurement_window_label = "full recording"
resource_window_label = "full recording"
reports_resource_metrics = scenario != "startup"
benchmark_elapsed = nil
benchmark_nominal_duration = nil
benchmark_overshoot = nil
if scroll_benchmark &&
   event_counts["#{measurement_interval}InsufficientHistory"].positive?
  raise "Authenticated scroll benchmark exhausted history before completing its workload"
end
if scroll_benchmark &&
   event_counts["#{measurement_interval}Cancelled"].positive?
  raise "Authenticated scroll benchmark was cancelled before completing its workload"
end
if scroll_benchmark &&
   event_counts["#{measurement_interval}PaginationFailed"].positive?
  raise "Authenticated scroll benchmark pagination failed"
end
if scroll_benchmark &&
   event_counts["#{measurement_interval}Completed"] != 1
  raise "Authenticated scroll benchmark requires exactly one completion event"
end
if scroll_benchmark && interval_bounds[measurement_interval].length != 1
  raise "Authenticated scroll benchmark requires exactly one measurement interval"
end
if scroll_benchmark
  benchmark_elapsed = Float(benchmark_result["elapsed_seconds"], exception: false)
  benchmark_nominal_duration = Float(
    benchmark_result["nominal_duration_seconds"], exception: false
  )
  benchmark_overshoot = Float(
    benchmark_result["elapsed_overshoot_seconds"], exception: false
  )
  completed_distance = Float(benchmark_result["completed_distance_points"], exception: false)
  nominal_distance = Float(benchmark_result["nominal_distance_points"], exception: false)
  distance_deficit = Float(benchmark_result["distance_deficit_points"], exception: false)
  spatial_quality = Float(benchmark_result["spatial_quality_ratio"], exception: false)
  completed_ticks = Integer(benchmark_result["completed_ticks"], exception: false)
  delayed_ticks = Integer(
    benchmark_result["delayed_ticks_over_33ms"], exception: false
  )
  delayed_tick_rate = Float(
    benchmark_result["delayed_tick_rate"], exception: false
  )
  median_tick_interval_ms = Float(
    benchmark_result["median_tick_interval_ms"], exception: false
  )
  p95_tick_interval_ms = Float(
    benchmark_result["p95_tick_interval_ms"], exception: false
  )
  p99_tick_interval_ms = Float(
    benchmark_result["p99_tick_interval_ms"], exception: false
  )
  delayed_tick_samples = benchmark_result[
    "delayed_tick_samples_offset_ms_interval_ms"
  ]&.split(",", -1)&.reject(&:empty?)&.map do |sample|
    offset, interval = sample.split(":", 2).map do |value|
      Float(value, exception: false)
    end
    [offset, interval]
  end
  maximum_tick_interval_ms = Float(
    benchmark_result["maximum_tick_interval_ms"], exception: false
  )
  maximum_scroll_work_ms = Float(
    benchmark_result["maximum_scroll_work_ms"], exception: false
  )
  history_starved_ticks = Integer(
    benchmark_result["history_starved_ticks"], exception: false
  )
  maximum_consecutive_history_starved_ticks = Integer(
    benchmark_result["maximum_consecutive_history_starved_ticks"], exception: false
  )
  render_keys = [
    "canvas_draw_count",
    "canvas_draw_total_ms",
    "canvas_draw_average_ms",
    "canvas_draw_maximum_ms",
    "row_raster_count",
    "row_raster_total_ms",
    "row_raster_average_ms",
    "row_raster_maximum_ms",
    "row_raster_maximum_height_points",
    "row_bitmap_cache_hit_count",
    "live_scroll_direct_paint_count",
  ]
  render_key_count = render_keys.count { |key| benchmark_result.key?(key) }
  has_render_metadata = render_key_count == render_keys.length
  if render_key_count.positive? && !has_render_metadata
    raise "Authenticated scroll benchmark has incomplete render metadata"
  end
  if has_render_metadata
    canvas_draw_count = Integer(
      benchmark_result["canvas_draw_count"], exception: false
    )
    canvas_draw_total_ms = Float(
      benchmark_result["canvas_draw_total_ms"], exception: false
    )
    canvas_draw_average_ms = Float(
      benchmark_result["canvas_draw_average_ms"], exception: false
    )
    canvas_draw_maximum_ms = Float(
      benchmark_result["canvas_draw_maximum_ms"], exception: false
    )
    row_raster_count = Integer(
      benchmark_result["row_raster_count"], exception: false
    )
    row_raster_total_ms = Float(
      benchmark_result["row_raster_total_ms"], exception: false
    )
    row_raster_average_ms = Float(
      benchmark_result["row_raster_average_ms"], exception: false
    )
    row_raster_maximum_ms = Float(
      benchmark_result["row_raster_maximum_ms"], exception: false
    )
    row_raster_maximum_height_points = Float(
      benchmark_result["row_raster_maximum_height_points"], exception: false
    )
    row_bitmap_cache_hit_count = Integer(
      benchmark_result["row_bitmap_cache_hit_count"], exception: false
    )
    live_scroll_direct_paint_count = Integer(
      benchmark_result["live_scroll_direct_paint_count"], exception: false
    )
    expected_canvas_draw_average = if canvas_draw_count&.positive?
                                     canvas_draw_total_ms / canvas_draw_count
                                   else
                                     0
                                   end
    expected_row_raster_average = if row_raster_count&.positive?
                                    row_raster_total_ms / row_raster_count
                                  else
                                    0
                                  end
    unless canvas_draw_count && canvas_draw_count >= 0 &&
           canvas_draw_total_ms&.finite? && canvas_draw_total_ms >= 0 &&
           canvas_draw_average_ms&.finite? && canvas_draw_average_ms >= 0 &&
           canvas_draw_maximum_ms&.finite? && canvas_draw_maximum_ms >= 0 &&
           row_raster_count && row_raster_count >= 0 &&
           row_raster_total_ms&.finite? && row_raster_total_ms >= 0 &&
           row_raster_average_ms&.finite? && row_raster_average_ms >= 0 &&
           row_raster_maximum_ms&.finite? && row_raster_maximum_ms >= 0 &&
           row_raster_maximum_height_points&.finite? &&
           row_raster_maximum_height_points >= 0 &&
           row_bitmap_cache_hit_count && row_bitmap_cache_hit_count >= 0 &&
           live_scroll_direct_paint_count && live_scroll_direct_paint_count >= 0 &&
           (canvas_draw_average_ms - expected_canvas_draw_average).abs < 0.000_001 &&
           (row_raster_average_ms - expected_row_raster_average).abs < 0.000_001 &&
           (canvas_draw_count.positive? || canvas_draw_total_ms.zero?) &&
           (canvas_draw_count.positive? || canvas_draw_maximum_ms.zero?) &&
           (row_raster_count.positive? || row_raster_total_ms.zero?) &&
           (row_raster_count.positive? || row_raster_maximum_ms.zero?) &&
           canvas_draw_maximum_ms <= canvas_draw_total_ms + 0.000_001 &&
           row_raster_maximum_ms <= row_raster_total_ms + 0.000_001
      raise "Authenticated scroll benchmark has invalid render metadata"
    end
  end
  signpost_elapsed = intervals[measurement_interval].first.to_f / 1_000.0
  unless benchmark_result["outcome"] == "completed" &&
         benchmark_elapsed&.finite? && benchmark_elapsed >= 20 &&
         benchmark_nominal_duration&.finite? &&
         (benchmark_nominal_duration - 20).abs < 0.000_001 &&
         benchmark_overshoot&.finite? && benchmark_overshoot >= 0 &&
         (benchmark_overshoot - (benchmark_elapsed - benchmark_nominal_duration)).abs < 0.001 &&
         (signpost_elapsed - benchmark_elapsed).abs < 0.050 &&
         completed_distance&.finite? && completed_distance >= 0 &&
         nominal_distance&.finite? && nominal_distance.positive? &&
         distance_deficit&.finite? && distance_deficit >= 0 &&
         spatial_quality&.finite? && spatial_quality.between?(0, 1) &&
         (distance_deficit - [nominal_distance - completed_distance, 0].max).abs < 0.001 &&
         (spatial_quality - [completed_distance / nominal_distance, 1].min).abs < 0.000_001
    raise "Authenticated scroll benchmark has invalid duration or spatial metadata"
  end
  has_tick_metadata = benchmark_result.key?("completed_ticks")
  distribution_keys = [
    "delayed_tick_rate",
    "median_tick_interval_ms",
    "p95_tick_interval_ms",
    "p99_tick_interval_ms",
    "delayed_tick_samples_offset_ms_interval_ms",
  ]
  distribution_key_count = distribution_keys.count do |key|
    benchmark_result.key?(key)
  end
  has_distribution_metadata = distribution_key_count == distribution_keys.length
  if distribution_key_count.positive? && !has_distribution_metadata
    raise "Authenticated scroll benchmark has incomplete frame-distribution metadata"
  end
  if has_tick_metadata &&
     !(completed_ticks&.positive? && delayed_ticks && delayed_ticks >= 0 &&
       delayed_ticks <= completed_ticks &&
       maximum_tick_interval_ms&.finite? &&
       maximum_tick_interval_ms >= 0 && maximum_scroll_work_ms&.finite? &&
       maximum_scroll_work_ms >= 0 && history_starved_ticks &&
       history_starved_ticks >= 0 &&
       maximum_consecutive_history_starved_ticks &&
       maximum_consecutive_history_starved_ticks >= 0 &&
       maximum_consecutive_history_starved_ticks <= history_starved_ticks)
    raise "Authenticated scroll benchmark has invalid tick metadata"
  end
  if has_distribution_metadata &&
     !(delayed_tick_rate&.finite? && delayed_tick_rate.between?(0, 1) &&
       (delayed_tick_rate - delayed_ticks.to_f / completed_ticks).abs < 0.000_001 &&
       median_tick_interval_ms&.finite? && median_tick_interval_ms >= 0 &&
       p95_tick_interval_ms&.finite? &&
       p95_tick_interval_ms >= median_tick_interval_ms &&
       p99_tick_interval_ms&.finite? &&
       p99_tick_interval_ms >= p95_tick_interval_ms &&
       delayed_tick_samples&.length == delayed_ticks &&
       delayed_tick_samples.all? do |offset, interval|
         offset&.finite? && offset >= 0 &&
           interval&.finite? && interval > 33
       end &&
       maximum_tick_interval_ms >= p99_tick_interval_ms)
    raise "Authenticated scroll benchmark has invalid frame-distribution metadata"
  end
  lower_bound, upper_bound = interval_bounds[measurement_interval].first
  scoped_intervals = {}
  intervals.each do |name, durations|
    matching = []
    durations.each_with_index do |duration, index|
      bounds = interval_bounds[name][index]
      if bounds && bounds[0] >= lower_bound && bounds[1] <= upper_bound
        matching << duration
      end
    end
    scoped_intervals[name] = matching unless matching.empty?
  end
  intervals = scoped_intervals
end
if navigation_benchmark
  unless interval_bounds[measurement_interval].length == 1 &&
         event_counts["AuthenticatedNavigationBenchmarkCompleted"] == 1 &&
         benchmark_result["outcome"] == "completed"
    raise "Authenticated navigation benchmark did not complete exactly once"
  end
  direct_message_count = Integer(
    benchmark_result["direct_message_count"], exception: false
  )
  server_count = Integer(benchmark_result["server_count"], exception: false)
  channel_count = Integer(benchmark_result["channel_count"], exception: false)
  unless direct_message_count&.positive? && server_count&.positive? &&
         channel_count&.positive?
    raise "Authenticated navigation benchmark requires DM, server, and channel samples"
  end
  {
    "direct-message" => "AuthenticatedDirectMessageOpen",
    "server" => "AuthenticatedServerOpen",
    "channel" => "AuthenticatedChannelOpen",
  }.each do |label, interval_name|
    history_network_subtracted_residuals = []
    network_durations = []
    all_network_durations = []
    other_rest_network_durations = []
    outer_minus_all_network_union = []
    conversation_load_residuals = []
    outside_conversation_load_residuals = []
    first_frame_residuals = []
    outside_first_frame_residuals = []
    stage_durations = navigation_stage_names.to_h { |name| [name, []] }
    interval_bounds[interval_name].each do |outer_start, outer_end|
      history_request = interval_bounds["ConversationHistoryRequest"].find do |start_at, end_at|
        start_at >= outer_start && end_at <= outer_end
      end
      next unless history_request
      history_start, history_end = history_request
      contained_network_bounds = interval_bounds[
        "MessageHistoryNetworkAttempt"
      ].each_with_object([]) do |(start_at, end_at), values|
        if start_at >= history_start && end_at <= history_end
          values << [start_at, end_at]
        end
      end
      next if contained_network_bounds.empty?
      network_duration = overlapping_interval_union_duration(
        contained_network_bounds,
        outer_start,
        outer_end
      )
      all_network_bounds = [
        "MessageHistoryNetworkAttempt",
        "RESTNetworkAttempt",
      ].flat_map { |name| interval_bounds[name] }
        .select do |start_at, end_at|
          start_at < outer_end && end_at > outer_start
        end
      all_network_duration = overlapping_interval_union_duration(
        all_network_bounds,
        outer_start,
        outer_end
      )
      other_rest_network_duration = overlapping_interval_union_duration(
        interval_bounds["RESTNetworkAttempt"],
        outer_start,
        outer_end
      )
      network_durations << network_duration
      all_network_durations << all_network_duration
      other_rest_network_durations << other_rest_network_duration
      outer_minus_all_network_union << [
        outer_end - outer_start - all_network_duration,
        0,
      ].max
      history_network_subtracted_residuals << [
        outer_end - outer_start - network_duration,
        0,
      ].max
      conversation_load = interval_bounds["ConversationLoad"].find do |start_at, end_at|
        start_at >= outer_start && end_at <= outer_end
      end
      if conversation_load
        load_start, load_end = conversation_load
        load_all_network_duration = overlapping_interval_union_duration(
          all_network_bounds,
          load_start,
          load_end
        )
        conversation_load_residuals << [
          load_end - load_start - load_all_network_duration,
          0,
        ].max
        outside_load_duration =
          outer_end - outer_start - (load_end - load_start)
        outside_load_all_network_duration =
          all_network_duration - load_all_network_duration
        outside_conversation_load_residuals << [
          outside_load_duration - outside_load_all_network_duration,
          0,
        ].max
      end
      first_frame = interval_bounds["ConversationNavigationToFirstFrame"].find do |start_at, end_at|
        start_at >= outer_start && end_at <= outer_end
      end
      if first_frame
        first_frame_start, first_frame_end = first_frame
        first_frame_all_network_duration = overlapping_interval_union_duration(
          all_network_bounds,
          first_frame_start,
          first_frame_end
        )
        first_frame_residuals << [
          first_frame_end - first_frame_start -
            first_frame_all_network_duration,
          0,
        ].max
        outside_first_frame_duration =
          outer_end - outer_start - (first_frame_end - first_frame_start)
        outside_first_frame_all_network_duration =
          all_network_duration - first_frame_all_network_duration
        outside_first_frame_residuals << [
          outside_first_frame_duration -
            outside_first_frame_all_network_duration,
          0,
        ].max
      end
      navigation_stage_names.each do |stage_name|
        duration = interval_bounds[stage_name].sum do |start_at, end_at|
          next 0 unless start_at >= outer_start && end_at <= outer_end
          end_at - start_at
        end
        stage_durations[stage_name] << duration
      end
    end
    # The app-controlled residual must remove the union of every REST attempt
    # overlapping the navigation window. Subtracting only the conversation's
    # history request misattributes concurrent profile, avatar, or guild REST
    # latency to SakuraCord and can turn network variance into a false app
    # regression. Keep the narrower value under an explicit diagnostic label.
    navigation_app_residuals[label] = outer_minus_all_network_union
    navigation_history_network_subtracted_residuals[label] =
      history_network_subtracted_residuals
    navigation_history_network[label] = network_durations
    navigation_all_network_union[label] = all_network_durations
    navigation_other_rest_network_overlap[label] =
      other_rest_network_durations
    navigation_outer_minus_all_network_union[label] =
      outer_minus_all_network_union
    navigation_conversation_load_residuals[label] = conversation_load_residuals
    navigation_outside_conversation_load_residuals[label] =
      outside_conversation_load_residuals
    navigation_first_frame_residuals[label] = first_frame_residuals
    navigation_outside_first_frame_residuals[label] =
      outside_first_frame_residuals
    navigation_stage_durations[label] = stage_durations
  end
  navigation_windows = interval_bounds[
    "ConversationNavigationToFirstFrame"
  ]
  interval_bounds["AnimatedImageDecode"].each do |decode_start, decode_end|
    overlap = 0.0
    navigation_windows.each do |navigation_start, navigation_end|
      overlap += [
        [decode_end, navigation_end].min -
          [decode_start, navigation_start].max,
        0,
      ].max
    end
    next unless overlap.positive?
    navigation_animation_decode_overlap_count += 1
    navigation_animation_decode_overlap_ms += overlap
    navigation_animation_decode_overlap_maximum_ms = [
      navigation_animation_decode_overlap_maximum_ms,
      overlap,
    ].max
  end
  [
    "TimelineVisibleStaticMediaDecode",
    "TimelinePrefetchStaticMediaDecode",
  ].each do |decode_name|
    interval_bounds[decode_name].each do |decode_start, decode_end|
      overlap = 0.0
      navigation_windows.each do |navigation_start, navigation_end|
        overlap += [
          [decode_end, navigation_end].min -
            [decode_start, navigation_start].max,
          0,
        ].max
      end
      next unless overlap.positive?
      navigation_static_decode_overlap_count += 1
      navigation_static_decode_overlap_ms += overlap
      navigation_static_decode_overlap_maximum_ms = [
        navigation_static_decode_overlap_maximum_ms,
        overlap,
      ].max
    end
  end
  lower_bound, upper_bound = interval_bounds[measurement_interval].first
  scoped_intervals = {}
  intervals.each do |name, durations|
    matching = []
    durations.each_with_index do |duration, index|
      bounds = interval_bounds[name][index]
      if bounds && bounds[0] >= lower_bound && bounds[1] <= upper_bound
        matching << duration
      end
    end
    scoped_intervals[name] = matching unless matching.empty?
  end
  intervals = scoped_intervals
end
if account_switch_benchmark
  unless interval_bounds[measurement_interval].length == 1 &&
         event_counts["AuthenticatedAccountSwitchBenchmarkCompleted"] == 1 &&
         benchmark_result["outcome"] == "completed" &&
         benchmark_result["switch_count"] == "1"
    raise "Authenticated account-switch benchmark did not complete exactly once"
  end
  lower_bound, upper_bound = interval_bounds[measurement_interval].first
  scoped_intervals = {}
  intervals.each do |name, durations|
    matching = []
    durations.each_with_index do |duration, index|
      bounds = interval_bounds[name][index]
      if bounds && bounds[0] >= lower_bound && bounds[1] <= upper_bound
        matching << duration
      end
    end
    scoped_intervals[name] = matching unless matching.empty?
  end
  intervals = scoped_intervals
end
if history_pagination_benchmark
  page_count = Integer(benchmark_result["page_count"], exception: false)
  unless interval_bounds[measurement_interval].length == 1 &&
         event_counts["AuthenticatedHistoryPaginationBenchmarkCompleted"] == 1 &&
         benchmark_result["outcome"] == "completed" &&
         page_count&.positive?
    raise "Authenticated history-pagination benchmark did not complete"
  end
  lower_bound, upper_bound = interval_bounds[measurement_interval].first
  scoped_intervals = {}
  intervals.each do |name, durations|
    matching = []
    durations.each_with_index do |duration, index|
      bounds = interval_bounds[name][index]
      if bounds && bounds[0] >= lower_bound && bounds[1] <= upper_bound
        matching << duration
      end
    end
    scoped_intervals[name] = matching unless matching.empty?
  end
  intervals = scoped_intervals
end
if scroll_interaction_benchmark
  completion_event = "#{measurement_interval}Completed"
  unless interval_bounds[measurement_interval].length == 1 &&
         event_counts[completion_event] == 1 &&
         benchmark_result["outcome"] == "completed"
    raise "Authenticated scroll-interaction benchmark did not complete exactly once"
  end
  if scenario == "authenticated-loading-scroll-overlap"
    initial_message_count = Integer(
      benchmark_result["initial_message_count"], exception: false
    )
    message_count = Integer(benchmark_result["message_count"], exception: false)
    display_fps = Float(
      benchmark_result["display_maximum_frames_per_second"], exception: false
    )
    surface = benchmark_result["surface"]
    gesture_intervals = {
      "timeline" => "TimelineGestureInputToDisplay",
      "member-list" => "MemberListGestureInputToDisplay",
      "channel-list" => "ChannelListGestureInputToDisplay",
      "server-list" => "ServerListGestureInputToDisplay",
    }
    unless benchmark_result["target"] == "Google Labs" &&
           interval_bounds["AuthenticatedLoadingScrollIdleControl"].length == 1 &&
           interval_bounds["AuthenticatedLoadingScrollWork"].length == 1 &&
           gesture_intervals.key?(surface) &&
           initial_message_count == 10 &&
           message_count && message_count >= 100 &&
           message_count > initial_message_count &&
           display_fps&.finite? && display_fps.positive?
      raise "Loading-scroll overlap requires Google Labs idle and loading intervals"
    end
    refresh_interval_ms = 1_000.0 / display_fps
    delayed_threshold_ms = refresh_interval_ms * 1.10
    phase_windows = {
      "idle" => interval_bounds["AuthenticatedLoadingScrollIdleControl"].first,
      "loading" => interval_bounds["AuthenticatedLoadingScrollWork"].first,
    }
    gesture_intervals.each do |label, interval_name|
      phase_metrics = {}
      phase_windows.each do |phase, (phase_start, phase_end)|
        durations = interval_bounds[interval_name].each_with_object([]) do |bounds, values|
          start_at, end_at = bounds
          values << end_at - start_at if start_at >= phase_start && end_at <= phase_end
        end
        next if durations.empty?
        phase_metrics[phase] = {
          count: durations.length,
          median: percentile(durations, 0.50),
          p95: percentile(durations, 0.95),
          p99: percentile(durations, 0.99),
          maximum: durations.max,
          delayed_rate:
            durations.count { |duration| duration > delayed_threshold_ms }.to_f /
              durations.length,
        }
      end
      next if phase_metrics.empty?
      if phase_metrics.key?("idle") && phase_metrics.key?("loading")
        idle_p95 = phase_metrics["idle"][:p95]
        loading_p95 = phase_metrics["loading"][:p95]
        phase_metrics["loading_to_idle_p95_ratio"] =
          idle_p95.positive? ? loading_p95 / idle_p95 : nil
      end
      loading_scroll_overlap_metrics[label] = phase_metrics
    end
    expected_metrics = loading_scroll_overlap_metrics[surface]
    has_gesture_coverage =
      (expected_metrics&.dig("idle", :count) || 0) >= 2 &&
      (expected_metrics&.dig("loading", :count) || 0) >= 2
    unless has_gesture_coverage || allows_missing_gestures
      raise "Loading-scroll overlap requires at least two idle and loading gestures on #{surface}"
    end
    loading_scroll_overlap_metrics["display_fps"] = display_fps
    loading_scroll_overlap_metrics["refresh_interval_ms"] = refresh_interval_ms
    loading_scroll_overlap_metrics["surface"] = surface
    loading_scroll_overlap_metrics["initial_message_count"] = initial_message_count
    loading_scroll_overlap_metrics["message_count"] = message_count
    loading_scroll_overlap_metrics["has_gesture_coverage"] = has_gesture_coverage
  end
  lower_bound, upper_bound = interval_bounds[measurement_interval].first
  scoped_intervals = {}
  intervals.each do |name, durations|
    matching = []
    durations.each_with_index do |duration, index|
      bounds = interval_bounds[name][index]
      if bounds && bounds[0] >= lower_bound && bounds[1] <= upper_bound
        matching << duration
      end
    end
    scoped_intervals[name] = matching unless matching.empty?
  end
  intervals = scoped_intervals
end
if scenario == "startup"
  if interval_bounds["StartupToWorkspace"].length != 1
    raise "Startup benchmark requires exactly one measurement interval for its launched process"
  end
  measurement_window_label = "StartupToWorkspace"
  resource_window_label =
    "not applicable: startup uses signpost-bounded Time Profiler samples"
  cpu = []
  cpu_average = nil
  rss = []
  sampled_physical_footprint = []
  top_power_proxy = []
  energy_rates_mw = []
  energy_average_mw = nil
  energy_total_mj = nil
  idle_wakeups_per_second = nil
  interrupt_wakeups_per_second = nil
  footprint = nil
  footprint_peak = nil
  network_in = []
  network_out = []
elsif measurement_interval
  if interval_bounds[measurement_interval].empty?
    raise "Missing required measurement signpost: #{measurement_interval}"
  end
  bounds = interval_bounds[measurement_interval].first
  resource_window_path = File.join(directory, "resource-window.tsv")
  resource_bounds =
    File.file?(resource_window_path) ? File.read(resource_window_path).split.map(&:to_i) : []
  lower_ns, upper_ns = resource_bounds
  if scroll_benchmark
    resource_elapsed =
      resource_bounds.length == 2 && upper_ns > lower_ns ?
        (upper_ns - lower_ns).to_f / 1_000_000_000.0 : nil
    unless resource_elapsed&.finite? &&
           (resource_elapsed - benchmark_nominal_duration).abs < 0.000_001
      raise "Authenticated scroll resource bounds must cover the exact nominal duration"
    end
  end
  sample_clock = :monotonic
  interpolate_sample = lambda do |target|
    exact = rusage_samples.find { |sample| sample[sample_clock] == target }
    next exact if exact
    after_index = rusage_samples.index do |sample|
      sample[sample_clock] && sample[sample_clock] > target
    end
    next nil unless after_index && after_index.positive?
    before = rusage_samples[after_index - 1]
    after = rusage_samples[after_index]
    next nil unless before[sample_clock]
    span = after[sample_clock] - before[sample_clock]
    next nil unless span.positive?
    fraction = (target - before[sample_clock]).to_f / span
    before.each_with_object({ sample_clock => target }) do |(key, value), result|
      next if key == sample_clock
      next if value.nil? || after[key].nil?
      result[key] = value + (after[key] - value) * fraction
    end
  end
  measurement_window_label = measurement_interval
  cpu = []
  rss = []
  sampled_physical_footprint = []
  top_power_proxy = []
  energy_rates_mw = []
  lower_sample = lower_ns && interpolate_sample.call(lower_ns)
  upper_sample = upper_ns && interpolate_sample.call(upper_ns)
  if resource_bounds.length == 2 && lower_sample && upper_sample && upper_ns > lower_ns
    raw_window_samples = rusage_samples.select do |sample|
      sample[sample_clock] &&
        sample[sample_clock] >= lower_ns && sample[sample_clock] <= upper_ns
    end
    window_samples = [lower_sample]
    window_samples.concat(
      rusage_samples.select do |sample|
        sample[sample_clock] &&
          sample[sample_clock] > lower_ns && sample[sample_clock] < upper_ns
      end
    )
    window_samples << upper_sample
    rusage_samples = window_samples
    resource_window_label = if benchmark_nominal_duration
                              "#{measurement_interval} nominal #{format('%.3f', benchmark_nominal_duration)} s"
                            else
                              "#{measurement_interval} exact request window"
                            end
    sampled_physical_footprint =
      raw_window_samples.map { |sample| sample[:footprint].to_f }
    window_samples.each_cons(2) do |before, after|
      elapsed = after[:elapsed] - before[:elapsed]
      next unless elapsed.positive?
      cpu_delta = after[:user] + after[:system] - before[:user] - before[:system]
      energy_delta = after[:energy] - before[:energy]
      cpu << cpu_delta.to_f / elapsed * 100.0 if cpu_delta >= 0
      energy_rates_mw << energy_delta.to_f / elapsed * 1_000.0 if energy_delta >= 0
    end
    first = window_samples.first
    last = window_samples.last
    window_duration_ns = upper_ns - lower_ns
    elapsed_seconds = window_duration_ns.to_f / 1_000_000_000.0
    total_cpu_delta =
      last[:user] + last[:system] - first[:user] - first[:system]
    total_energy_delta = last[:energy] - first[:energy]
    cpu_average = total_cpu_delta.to_f / window_duration_ns * 100.0
    energy_average_mw = total_energy_delta.to_f / window_duration_ns * 1_000.0
    energy_total_mj = (last[:energy] - first[:energy]).to_f / 1_000_000.0
    idle_wakeups_per_second =
      (last[:idle] - first[:idle]).to_f / elapsed_seconds
    interrupt_wakeups_per_second =
      (last[:interrupt] - first[:interrupt]).to_f / elapsed_seconds
    footprint = nil
    footprint_peak = nil
  else
    resource_window_label =
      "unavailable: sampler does not cover #{measurement_interval}"
    rusage_samples = []
    cpu_average = nil
    energy_average_mw = nil
    sampled_physical_footprint = []
    energy_total_mj = nil
    idle_wakeups_per_second = nil
    interrupt_wakeups_per_second = nil
    footprint = nil
    footprint_peak = nil
  end
  # nettop and top are retained as raw diagnostics, but their independent
  # one-second clocks cannot be sliced to subsecond signpost bounds without
  # inventing precision. Do not report them as workload-window measurements.
  network_in = []
  network_out = []
end

main_thread_overlap_bounds = interval_bounds
scopes_intervals_to_measurement =
  scroll_benchmark || navigation_benchmark || account_switch_benchmark ||
    history_pagination_benchmark || scroll_interaction_benchmark
if scopes_intervals_to_measurement && measurement_interval &&
   interval_bounds[measurement_interval].length == 1
  lower_bound, upper_bound = interval_bounds[measurement_interval].first
  main_thread_overlap_bounds = interval_bounds.each_with_object({}) do |(name, bounds), result|
    matching = bounds.select do |started_at, ended_at|
      started_at >= lower_bound && ended_at <= upper_bound
    end
    result[name] = matching unless matching.empty?
  end
end
reported_event_counts = event_counts
if scopes_intervals_to_measurement && measurement_interval &&
   interval_bounds[measurement_interval].length == 1
  lower_bound, upper_bound = interval_bounds[measurement_interval].first
  reported_event_counts = event_bounds.each_with_object({}) do |(name, times), result|
    count = times.count { |time| time >= lower_bound && time <= upper_bound }
    result[name] = count if count.positive?
  end
end
main_thread_overlap = main_thread_overlap_bounds.each_with_object({}) do |(name, bounds), result|
  result[name] = bounds.map do |started_at, ended_at|
    main_thread_samples.sum do |sample_time, sample_weight|
      sample_time >= started_at && sample_time <= ended_at ? sample_weight : 0.0
    end
  end
end

puts "SakuraCord performance summary"
puts "artifact\t#{directory}"
puts "measurement.window\t#{measurement_window_label}"
puts "resources.window\t#{resource_window_label}"
if measurement_profile_sampled_ms
  puts "time-profile.measurement.cpu-sampled\t#{format_metric(measurement_profile_sampled_ms, "ms")}"
end
if outline_list_profile_sampled_ms
  puts "time-profile.outline-list.cpu-sampled\t#{format_metric(outline_list_profile_sampled_ms, "ms")}"
end
if delayed_frame_profile_sampled_ms
  puts "time-profile.delayed-frame-windows.cpu-sampled\t#{format_metric(delayed_frame_profile_sampled_ms, "ms")}"
end
if scroll_benchmark
  puts "duration.nominal\t#{benchmark_result["nominal_duration_seconds"]} s"
  puts "duration.ui-stop\t#{benchmark_result["elapsed_seconds"]} s"
  puts "duration.overshoot\t#{benchmark_result["elapsed_overshoot_seconds"]} s"
  puts "spatial.distance.completed\t#{benchmark_result["completed_distance_points"]} points"
  puts "spatial.distance.nominal\t#{benchmark_result["nominal_distance_points"]} points"
  puts "spatial.distance.deficit\t#{benchmark_result["distance_deficit_points"]} points"
  puts "spatial.quality\t#{benchmark_result["spatial_quality_ratio"]} ratio"
  if benchmark_result.key?("completed_ticks")
    puts "frames.completed\t#{benchmark_result["completed_ticks"]}"
    puts "frames.delayed-over-33ms\t#{benchmark_result["delayed_ticks_over_33ms"]}"
    if benchmark_result.key?("median_tick_interval_ms")
      puts "frames.delayed-rate\t#{benchmark_result["delayed_tick_rate"]} ratio"
      puts "frames.interval.median\t#{benchmark_result["median_tick_interval_ms"]} ms"
      puts "frames.interval.p95\t#{benchmark_result["p95_tick_interval_ms"]} ms"
      puts "frames.interval.p99\t#{benchmark_result["p99_tick_interval_ms"]} ms"
      puts "frames.delayed-samples.offset-ms:interval-ms\t#{benchmark_result["delayed_tick_samples_offset_ms_interval_ms"]}"
    end
    puts "frames.maximum-interval\t#{benchmark_result["maximum_tick_interval_ms"]} ms"
    puts "scroll-work.maximum\t#{benchmark_result["maximum_scroll_work_ms"]} ms"
    puts "history-starved.ticks\t#{benchmark_result["history_starved_ticks"]}"
    puts "history-starved.maximum-consecutive\t#{benchmark_result["maximum_consecutive_history_starved_ticks"]}"
  end
  if has_render_metadata
    puts "render.canvas-draw.count\t#{benchmark_result["canvas_draw_count"]}"
    puts "render.canvas-draw.total\t#{benchmark_result["canvas_draw_total_ms"]} ms"
    puts "render.canvas-draw.average\t#{benchmark_result["canvas_draw_average_ms"]} ms"
    puts "render.canvas-draw.maximum\t#{benchmark_result["canvas_draw_maximum_ms"]} ms"
    puts "render.row-raster.count\t#{benchmark_result["row_raster_count"]}"
    puts "render.row-raster.total\t#{benchmark_result["row_raster_total_ms"]} ms"
    puts "render.row-raster.average\t#{benchmark_result["row_raster_average_ms"]} ms"
    puts "render.row-raster.maximum\t#{benchmark_result["row_raster_maximum_ms"]} ms"
    puts "render.row-raster.maximum-height\t#{benchmark_result["row_raster_maximum_height_points"]} points"
    puts "render.row-bitmap-cache-hits\t#{benchmark_result["row_bitmap_cache_hit_count"]}"
    puts "render.live-scroll-direct-paints\t#{benchmark_result["live_scroll_direct_paint_count"]}"
  end
end
if navigation_benchmark
  puts "navigation.direct-messages\t#{benchmark_result["direct_message_count"]}"
  puts "navigation.servers\t#{benchmark_result["server_count"]}"
  puts "navigation.channels\t#{benchmark_result["channel_count"]}"
  navigation_app_residuals.each do |label, values|
    next if values.empty?
    puts "navigation.#{label}.app-controlled-residual.median\t#{format_metric(percentile(values, 0.5), "ms")}"
    puts "navigation.#{label}.app-controlled-residual.p95\t#{format_metric(percentile(values, 0.95), "ms")}"
  end
  navigation_history_network_subtracted_residuals.each do |label, values|
    next if values.empty?
    puts "navigation.#{label}.history-network-subtracted-residual.median\t#{format_metric(percentile(values, 0.5), "ms")}"
    puts "navigation.#{label}.history-network-subtracted-residual.p95\t#{format_metric(percentile(values, 0.95), "ms")}"
  end
  navigation_history_network.each do |label, values|
    next if values.empty?
    puts "navigation.#{label}.history-network.median\t#{format_metric(percentile(values, 0.5), "ms")}"
    puts "navigation.#{label}.history-network.p95\t#{format_metric(percentile(values, 0.95), "ms")}"
  end
  navigation_all_network_union.each do |label, values|
    next if values.empty?
    puts "navigation.#{label}.all-network-union.median\t#{format_metric(percentile(values, 0.5), "ms")}"
    puts "navigation.#{label}.all-network-union.p95\t#{format_metric(percentile(values, 0.95), "ms")}"
  end
  navigation_other_rest_network_overlap.each do |label, values|
    next if values.empty?
    puts "navigation.#{label}.other-rest-network-overlap.median\t#{format_metric(percentile(values, 0.5), "ms")}"
    puts "navigation.#{label}.other-rest-network-overlap.p95\t#{format_metric(percentile(values, 0.95), "ms")}"
  end
  navigation_outer_minus_all_network_union.each do |label, values|
    next if values.empty?
    puts "navigation.#{label}.outer-minus-all-network-union.median\t#{format_metric(percentile(values, 0.5), "ms")}"
    puts "navigation.#{label}.outer-minus-all-network-union.p95\t#{format_metric(percentile(values, 0.95), "ms")}"
  end
  navigation_conversation_load_residuals.each do |label, values|
    next if values.empty?
    puts "navigation.#{label}.conversation-load-app-residual.median\t#{format_metric(percentile(values, 0.5), "ms")}"
    puts "navigation.#{label}.conversation-load-app-residual.p95\t#{format_metric(percentile(values, 0.95), "ms")}"
  end
  navigation_outside_conversation_load_residuals.each do |label, values|
    next if values.empty?
    puts "navigation.#{label}.outside-conversation-load-app-residual.median\t#{format_metric(percentile(values, 0.5), "ms")}"
    puts "navigation.#{label}.outside-conversation-load-app-residual.p95\t#{format_metric(percentile(values, 0.95), "ms")}"
  end
  navigation_first_frame_residuals.each do |label, values|
    next if values.empty?
    puts "navigation.#{label}.first-frame-app-residual.median\t#{format_metric(percentile(values, 0.5), "ms")}"
    puts "navigation.#{label}.first-frame-app-residual.p95\t#{format_metric(percentile(values, 0.95), "ms")}"
  end
  navigation_outside_first_frame_residuals.each do |label, values|
    next if values.empty?
    puts "navigation.#{label}.outside-first-frame-app-residual.median\t#{format_metric(percentile(values, 0.5), "ms")}"
    puts "navigation.#{label}.outside-first-frame-app-residual.p95\t#{format_metric(percentile(values, 0.95), "ms")}"
  end
  navigation_stage_durations.each do |label, stages|
    stages.each do |stage_name, values|
      next if values.empty? || values.none?(&:positive?)
      puts "navigation.#{label}.stage.#{stage_name}.median\t#{format_metric(percentile(values, 0.5), "ms")}"
      puts "navigation.#{label}.stage.#{stage_name}.p95\t#{format_metric(percentile(values, 0.95), "ms")}"
    end
  end
  puts "navigation.animated-decode-overlap.count\t#{navigation_animation_decode_overlap_count}"
  puts "navigation.animated-decode-overlap.total\t#{format_metric(navigation_animation_decode_overlap_ms, "ms")}"
  puts "navigation.animated-decode-overlap.maximum\t#{format_metric(navigation_animation_decode_overlap_maximum_ms, "ms")}"
  puts "navigation.static-decode-overlap.count\t#{navigation_static_decode_overlap_count}"
  puts "navigation.static-decode-overlap.total\t#{format_metric(navigation_static_decode_overlap_ms, "ms")}"
  puts "navigation.static-decode-overlap.maximum\t#{format_metric(navigation_static_decode_overlap_maximum_ms, "ms")}"
end
if account_switch_benchmark
  puts "account-switch.count\t#{benchmark_result["switch_count"]}"
  if benchmark_result["source_account_id"] && !benchmark_result["source_account_id"].empty?
    puts "account-switch.source-account-id\t#{benchmark_result["source_account_id"]}"
  end
  if benchmark_result["target_account_id"] && !benchmark_result["target_account_id"].empty?
    puts "account-switch.target-account-id\t#{benchmark_result["target_account_id"]}"
  end
end
if history_pagination_benchmark
  puts "history-pagination.pages\t#{benchmark_result["page_count"]}"
end
unless loading_scroll_overlap_metrics.empty?
  puts "loading-scroll.surface\t#{loading_scroll_overlap_metrics["surface"]}"
  puts "loading-scroll.gesture-coverage\t#{loading_scroll_overlap_metrics["has_gesture_coverage"]}"
  puts "loading-scroll.display-maximum-fps\t#{loading_scroll_overlap_metrics["display_fps"]} Hz"
  puts "loading-scroll.refresh-interval\t#{format_metric(loading_scroll_overlap_metrics["refresh_interval_ms"], "ms")}"
  puts "loading-scroll.initial-messages\t#{loading_scroll_overlap_metrics["initial_message_count"]}"
  puts "loading-scroll.final-messages\t#{loading_scroll_overlap_metrics["message_count"]}"
  unless benchmark_result["target_channel_id"].to_s.empty?
    puts "loading-scroll.target-channel-id\t#{benchmark_result["target_channel_id"]}"
  end
  unless benchmark_result["target_channel_name"].to_s.empty?
    puts "loading-scroll.target-channel-name\t#{benchmark_result["target_channel_name"]}"
  end
  %w[timeline member-list channel-list server-list].each do |surface|
    metrics = loading_scroll_overlap_metrics[surface]
    next unless metrics
    %w[idle loading].each do |phase|
      values = metrics[phase]
      next unless values
      prefix = "loading-scroll.#{surface}.#{phase}"
      puts "#{prefix}.gestures\t#{values[:count]}"
      puts "#{prefix}.input-latency.median\t#{format_metric(values[:median], "ms")}"
      puts "#{prefix}.input-latency.p95\t#{format_metric(values[:p95], "ms")}"
      puts "#{prefix}.input-latency.p99\t#{format_metric(values[:p99], "ms")}"
      puts "#{prefix}.input-latency.maximum\t#{format_metric(values[:maximum], "ms")}"
      puts "#{prefix}.delayed-over-refresh\t#{format_metric(values[:delayed_rate] * 100, "%")}"
    end
    ratio = metrics["loading_to_idle_p95_ratio"]
    next unless ratio
    puts "loading-scroll.#{surface}.loading-vs-idle.p95-ratio\t#{format_metric(ratio, "x")}"
    puts "loading-scroll.#{surface}.loading-vs-idle.within-10-percent\t#{ratio <= 1.10}"
  end
end
if reports_resource_metrics
  puts "samples\t#{cpu.length}"
  unless cpu.empty?
    puts "cpu.average\t#{format_metric(cpu_average || cpu.sum / cpu.length, "%")}"
    puts "cpu.p95\t#{format_metric(percentile(cpu, 0.95), "%")}"
    puts "cpu.maximum\t#{format_metric(cpu.max, "%")}"
  end
  unless energy_rates_mw.empty?
    puts "energy.average\t#{format_metric(energy_average_mw || energy_rates_mw.sum / energy_rates_mw.length, "mW")}"
    puts "energy.p95\t#{format_metric(percentile(energy_rates_mw, 0.95), "mW")}"
    puts "energy.maximum\t#{format_metric(energy_rates_mw.max, "mW")}"
    puts "energy.total\t#{format_metric(energy_total_mj, "mJ")}"
    puts "wakeups.idle.average\t#{format_metric(idle_wakeups_per_second, "/s")}"
    puts "wakeups.interrupt.average\t#{format_metric(interrupt_wakeups_per_second, "/s")}"
  end
  unless top_power_proxy.empty?
    puts "top.power-proxy.average\t#{format_metric(top_power_proxy.sum / top_power_proxy.length, "CPU-like units")}"
    puts "top.power-proxy.maximum\t#{format_metric(top_power_proxy.max, "CPU-like units")}"
  end
  unless rss.empty?
    puts "rss.minimum\t#{format_metric(rss.min / 1_048_576.0, "MiB")}"
    puts "rss.maximum\t#{format_metric(rss.max / 1_048_576.0, "MiB")}"
  end
  unless sampled_physical_footprint.empty?
    puts "physical-footprint.sampled.minimum\t#{format_metric(sampled_physical_footprint.min / 1_048_576.0, "MiB")}"
    puts "physical-footprint.sampled.maximum\t#{format_metric(sampled_physical_footprint.max / 1_048_576.0, "MiB")}"
  end
  if footprint || footprint_peak
    puts "footprint.current\t#{format_metric(footprint&./(1_048_576.0), "MiB")}"
    puts "footprint.peak\t#{format_metric(footprint_peak&./(1_048_576.0), "MiB")}"
  end
  if network_in.length >= 2 && network_out.length >= 2
    puts "network.received\t#{network_in.max - network_in.min} bytes"
    puts "network.sent\t#{network_out.max - network_out.min} bytes"
  end
else
  puts "startup.cpu-source\tTime Profiler samples in startup-time-profile.txt"
end
intervals.sort.each do |name, durations|
  next if durations.empty?
  puts "signpost.#{name}.count\t#{durations.length}"
  puts "signpost.#{name}.total\t#{format_metric(durations.sum, "ms")}"
  puts "signpost.#{name}.average\t#{format_metric(durations.sum / durations.length, "ms")}"
  puts "signpost.#{name}.median\t#{format_metric(percentile(durations, 0.50), "ms")}"
  puts "signpost.#{name}.p95\t#{format_metric(percentile(durations, 0.95), "ms")}"
  puts "signpost.#{name}.p99\t#{format_metric(percentile(durations, 0.99), "ms")}"
  puts "signpost.#{name}.maximum\t#{format_metric(durations.max, "ms")}"
  sampled_overlap = main_thread_overlap[name]
  if sampled_overlap && !sampled_overlap.empty?
    prefix = "signpost.#{name}.main-thread-overlap-sampled"
    puts "#{prefix}.count\t#{sampled_overlap.length}"
    puts "#{prefix}.total\t#{format_metric(sampled_overlap.sum, "ms")}"
    puts "#{prefix}.average\t#{format_metric(sampled_overlap.sum / sampled_overlap.length, "ms")}"
    puts "#{prefix}.p95\t#{format_metric(percentile(sampled_overlap, 0.95), "ms")}"
    puts "#{prefix}.p99\t#{format_metric(percentile(sampled_overlap, 0.99), "ms")}"
    puts "#{prefix}.maximum\t#{format_metric(sampled_overlap.max, "ms")}"
  end
end
reported_event_counts.sort.each do |name, count|
  puts "event.#{name}.count\t#{count}"
end
unmatched_signposts.sort.each do |name, count|
  puts "signpost.#{name}.unmatched\t#{count}" if count.positive?
end
RUBY
}

command="${1:-}"
case "$command" in
    build)
        cd "$root"
        SAKURACORD_INSECURE_DEBUG_CREDENTIALS=1 \
            ./script/build_and_run.sh run
        record_build_provenance
        ;;
    record)
        scenario="${2:-active}"
        seconds="${3:-30}"
        template="${4:-Time Profiler}"
        record_running_app "$scenario" "$seconds" "$template"
        ;;
    startup)
        record_startup "${2:-12}"
        ;;
    authenticated-scroll)
        record_authenticated_scroll "${2:-35}"
        ;;
    authenticated-member-list-scroll)
        record_authenticated_member_list_scroll "${2:-70}"
        ;;
    authenticated-gesture-scroll)
        record_authenticated_gesture_scroll "${2:-40}"
        ;;
    authenticated-loading-scroll-overlap)
        record_authenticated_loading_scroll_overlap "${2:-55}" "${3:-timeline}"
        ;;
    authenticated-navigation)
        record_authenticated_navigation "${2:-45}"
        ;;
    authenticated-account-switch)
        record_authenticated_account_switch "${2:-45}"
        ;;
    authenticated-history-pagination)
        record_authenticated_history_pagination "${2:-45}"
        ;;
    authenticated-search)
        record_authenticated_search "${2:-45}"
        ;;
    authenticated-search-pagination)
        record_authenticated_search_pagination "${2:-50}"
        ;;
    authenticated-search-scroll)
        record_authenticated_search_scroll "${2:-50}"
        ;;
    snapshot)
        pid="$(require_running_pid)"
        top -pid "$pid" -l 1 -stats pid,cpu,mem,threads,power -o cpu
        footprint "$pid" || true
        nettop -P -p "$pid" -L 1 -x -n || true
        ;;
    summarize)
        summarize_recording "${2:?artifact directory is required}"
        ;;
    provenance-record)
        record_build_provenance
        ;;
    provenance-check)
        verify_build_provenance >/dev/null
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac
