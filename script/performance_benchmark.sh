#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime="$("$root/script/worktree_runtime.sh")"
checkout="$(sed -n 's/^Checkout:  *//p' <<<"$runtime")"
app="$(sed -n 's/^App:  *//p' <<<"$runtime")"
executable="${SAKURACORD_PERFORMANCE_EXECUTABLE_OVERRIDE:-$app/Contents/MacOS/SakuraCord}"
provenance_directory="${SAKURACORD_PERFORMANCE_PROVENANCE_DIRECTORY_OVERRIDE:-$root/.build/performance-tools/build-provenance}"

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
#       nominal 192,000-point path, and quality ratio are recorded separately. The
#       channel must already have at least 100 cached messages. This never
#       synthesizes user interaction, marks content read, sends a message, or
#       enables an offline fixture. Defaults: 35 seconds.
#   snapshot
#       Print a one-shot CPU, RSS, thread, footprint, and network sample.
#   summarize <artifact-directory>
#       Produce a deterministic scenario-appropriate summary. Authenticated
#       scroll uses exact monotonic workload bounds for process counters;
#       startup uses signpost-bounded Time Profiler samples. Writes summary.txt
#       beside the raw capture. Activity Monitor's normalized Energy Impact
#       number is private and is not the same measurement as top's power column.
#
# Artifacts are written beneath .build/performance and remain untracked.

require_main_checkout() {
    if [[ "$checkout" != main* ]]; then
        printf '%s\n' "Authenticated benchmarks are restricted to the canonical checkout." >&2
        exit 2
    fi
}

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
        git -C "$root" diff --binary HEAD \
            | shasum -a 256 | awk '{print $1}'
    )"
    {
        printf 'tracked-diff\t%s\n' "$tracked_diff_hash"
        git -C "$root" ls-files --others --exclude-standard \
            | LC_ALL=C sort \
            | while IFS= read -r relative; do
                [[ -n "$relative" ]] || continue
                file_hash="$(
                    shasum -a 256 "$root/$relative" | awk '{print $1}'
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
        printf 'git_revision\t%s\n' "$(git -C "$root" rev-parse HEAD)"
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
        printf 'git_revision\t%s\n' "$(git -C "$root" rev-parse HEAD)"
        printf 'tracked_diff_sha256\t%s\n' "$tracked_diff_hash"
        printf 'source_state_sha256\t%s\n' "$source_state_hash"
        printf 'build_source_state_sha256\t%s\n' "$build_source_state_hash"
        printf 'executable_sha256\t%s\n' "$executable_hash"
        printf 'checkout\t%s\n' "$checkout"
        printf 'app\t%s\n' "$app"
        printf 'macos\t%s\n' "$(sw_vers -productVersion)"
        printf 'build\t%s\n' "$(sw_vers -buildVersion)"
        printf 'hardware\t%s\n' "$(sysctl -n hw.model)"
        printf 'architecture\t%s\n' "$(uname -m)"
    } >"$output/metadata.tsv"
    git -C "$root" status --porcelain=v1 >"$output/working-tree.txt"
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

record_running_app() {
    local scenario="$1" seconds="$2" template="$3" pid output trace samples sampler
    local notification notify_pid trace_pid top_pid energy_pid nettop_pid
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
    notifyutil -1 "$notification" >"$output/trace-start-notification.txt" &
    notify_pid=$!
    xcrun xctrace record \
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
    "$sampler" "$pid" "$seconds" 250 >"$output/rusage-energy.csv" \
        2>"$output/rusage-energy-error.txt" &
    energy_pid=$!
    nettop -P -p "$pid" -L "$samples" -s 1 -x -n \
        >"$output/network.csv" 2>"$output/network-error.txt" &
    nettop_pid=$!
    touch "$output/interaction-ready"
    printf '%s\n' \
        "Recording active: $scenario." \
        "Use SakuraCord normally now; do not send messages or mutate account data."
    wait "$trace_pid"
    wait "$top_pid" || true
    wait "$energy_pid" || true
    wait "$nettop_pid" || true
    export_trace_tables "$trace" "$output"
    footprint "$pid" >"$output/footprint.txt" 2>"$output/footprint-error.txt" || true
    printf '%s\n' "Completed: $output"
}

record_launch() {
    local scenario="$1" seconds="$2" pid output trace trace_pid notify_pid notification sampler
    local resource_window_name
    shift 2
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
    write_recording_metadata "$output" "$scenario" "Time Profiler"
    case "$scenario" in
        authenticated-scroll) resource_window_name="MessageTimelineAutoScrollBenchmark" ;;
        *) resource_window_name="" ;;
    esac
    notifyutil -1 "$notification" >"$output/trace-start-notification.txt" &
    notify_pid=$!
    xcrun xctrace record \
        --template 'Time Profiler' \
        --time-limit "${seconds}s" \
        --no-prompt \
        --notify-tracing-started "$notification" \
        --output "$trace" \
        --env SAKURACORD_INSECURE_DEBUG_CREDENTIALS=1 \
        --env SAKURACORD_PERFORMANCE_WINDOW_NAME="$resource_window_name" \
        --env SAKURACORD_PERFORMANCE_WINDOW_PATH="$output/resource-window.tsv" \
        --env SAKURACORD_PERFORMANCE_RESULT_PATH="$output/benchmark-result.tsv" \
        --launch -- "$executable" "$@" &
    trace_pid=$!
    wait_for_trace_start "$notify_pid" "$trace_pid" "$output"
    pid=""
    for _ in {1..200}; do
        if pid="$(running_pid || true)"; [[ -n "$pid" ]]; then
            printf '%s\n' "$pid" >"$output/app-pid.txt"
            break
        fi
        sleep 0.02
    done
    if [[ "$scenario" == "authenticated-scroll" && -n "$pid" ]]; then
        top -pid "$pid" -l "$seconds" -s 1 \
            -stats pid,cpu,mem,threads,power -o cpu \
            >"$output/activity-monitor.txt" &
        local top_pid=$!
        sampler="$(ensure_rusage_sampler)"
        "$sampler" "$pid" "$seconds" 250 \
            >"$output/rusage-energy.csv" \
            2>"$output/rusage-energy-error.txt" &
        local energy_pid=$!
        nettop -P -p "$pid" -L "$seconds" -s 1 -x -n \
            >"$output/network.csv" 2>"$output/network-error.txt" &
        local nettop_pid=$!
    fi
    wait "$trace_pid"
    if [[ "$scenario" == "authenticated-scroll" && -n "$pid" ]]; then
        wait "$top_pid" || true
        wait "$energy_pid" || true
        wait "$nettop_pid" || true
        footprint "$pid" >"$output/footprint.txt" \
            2>"$output/footprint-error.txt" || true
    fi
    export_trace_tables "$trace" "$output"
    printf '%s\n' "Completed: $output"
}

record_startup() {
    record_launch startup "$1"
}

record_authenticated_scroll() {
    record_launch authenticated-scroll "$1" \
        --debug-authenticated-chat-performance-autoscroll
}

summarize_recording() {
    local output="$1"
    if [[ ! -d "$output" ]]; then
        printf '%s\n' "Benchmark artifact directory does not exist: $output" >&2
        exit 6
    fi
    local scenario profile_process
    scenario="$(
        awk -F '\t' '$1 == "scenario" { print $2 }' "$output/metadata.tsv"
    )"
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
    /usr/bin/ruby -r csv -r rexml/document - "$output" <<'RUBY' \
        | tee "$output/summary.txt"
directory = File.expand_path(ARGV.fetch(0))

def percentile(values, fraction)
  return nil if values.empty?
  sorted = values.sort
  sorted[[(sorted.length * fraction).ceil - 1, 0].max]
end

def format_metric(value, unit)
  value ? format("%.3f %s", value, unit) : "unavailable"
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
    process = display_values["process"] || display_values["thread"] || "unknown"
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
    end
  end
  starts.each do |key, values|
    unmatched_signposts[key.last] += values.length
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
measurement_interval = case scenario
                       when "authenticated-scroll"
                         "MessageTimelineAutoScrollBenchmark"
                       when "startup"
                         "StartupToWorkspace"
                       end
measurement_window_label = "full recording"
resource_window_label = "full recording"
reports_resource_metrics = scenario != "startup"
benchmark_elapsed = nil
benchmark_nominal_duration = nil
benchmark_overshoot = nil
if scenario == "authenticated-scroll" &&
   event_counts["MessageTimelineAutoScrollBenchmarkInsufficientHistory"].positive?
  raise "Authenticated scroll benchmark exhausted history before completing its workload"
end
if scenario == "authenticated-scroll" &&
   event_counts["MessageTimelineAutoScrollBenchmarkCancelled"].positive?
  raise "Authenticated scroll benchmark was cancelled before completing its workload"
end
if scenario == "authenticated-scroll" &&
   event_counts["MessageTimelineAutoScrollBenchmarkPaginationFailed"].positive?
  raise "Authenticated scroll benchmark pagination failed"
end
if scenario == "authenticated-scroll" &&
   event_counts["MessageTimelineAutoScrollBenchmarkCompleted"] != 1
  raise "Authenticated scroll benchmark requires exactly one completion event"
end
if scenario == "authenticated-scroll" &&
   interval_bounds["MessageTimelineAutoScrollBenchmark"].length != 1
  raise "Authenticated scroll benchmark requires exactly one measurement interval"
end
if scenario == "authenticated-scroll"
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
  signpost_elapsed = intervals["MessageTimelineAutoScrollBenchmark"].first.to_f / 1_000.0
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
  if scenario == "authenticated-scroll"
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
    resource_window_label =
      "#{measurement_interval} nominal #{format('%.3f', benchmark_nominal_duration)} s"
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

puts "SakuraCord performance summary"
puts "artifact\t#{directory}"
puts "measurement.window\t#{measurement_window_label}"
puts "resources.window\t#{resource_window_label}"
if scenario == "authenticated-scroll"
  puts "duration.nominal\t#{benchmark_result["nominal_duration_seconds"]} s"
  puts "duration.ui-stop\t#{benchmark_result["elapsed_seconds"]} s"
  puts "duration.overshoot\t#{benchmark_result["elapsed_overshoot_seconds"]} s"
  puts "spatial.distance.completed\t#{benchmark_result["completed_distance_points"]} points"
  puts "spatial.distance.nominal\t#{benchmark_result["nominal_distance_points"]} points"
  puts "spatial.distance.deficit\t#{benchmark_result["distance_deficit_points"]} points"
  puts "spatial.quality\t#{benchmark_result["spatial_quality_ratio"]} ratio"
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
  puts "signpost.#{name}.median\t#{format_metric(percentile(durations, 0.50), "ms")}"
  puts "signpost.#{name}.p95\t#{format_metric(percentile(durations, 0.95), "ms")}"
  puts "signpost.#{name}.maximum\t#{format_metric(durations.max, "ms")}"
end
unmatched_signposts.sort.each do |name, count|
  puts "signpost.#{name}.unmatched\t#{count}" if count.positive?
end
RUBY
}

command="${1:-}"
case "$command" in
    build)
        require_main_checkout
        cd "$root"
        SAKURACORD_INSECURE_DEBUG_CREDENTIALS=1 \
            ./script/build_and_run.sh run
        record_build_provenance
        ;;
    record)
        require_main_checkout
        scenario="${2:-active}"
        seconds="${3:-30}"
        template="${4:-Time Profiler}"
        record_running_app "$scenario" "$seconds" "$template"
        ;;
    startup)
        require_main_checkout
        record_startup "${2:-12}"
        ;;
    authenticated-scroll)
        require_main_checkout
        record_authenticated_scroll "${2:-35}"
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
