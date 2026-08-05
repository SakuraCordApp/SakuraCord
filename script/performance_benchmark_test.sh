#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$root/script/fixtures/performance-overlap"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/sakuracord-performance-test.XXXXXX")"
member_list_temporary="$(mktemp -d "${TMPDIR:-/tmp}/sakuracord-member-list-performance-test.XXXXXX")"
startup_temporary="$(mktemp -d "${TMPDIR:-/tmp}/sakuracord-startup-test.XXXXXX")"
insufficient_temporary="$(mktemp -d "${TMPDIR:-/tmp}/sakuracord-insufficient-test.XXXXXX")"
cancelled_temporary="$(mktemp -d "${TMPDIR:-/tmp}/sakuracord-cancelled-test.XXXXXX")"
missing_outcome_temporary="$(mktemp -d "${TMPDIR:-/tmp}/sakuracord-missing-outcome-test.XXXXXX")"
pagination_failed_temporary="$(mktemp -d "${TMPDIR:-/tmp}/sakuracord-pagination-failed-test.XXXXXX")"
short_distance_temporary="$(mktemp -d "${TMPDIR:-/tmp}/sakuracord-short-distance-test.XXXXXX")"
missing_elapsed_temporary="$(mktemp -d "${TMPDIR:-/tmp}/sakuracord-missing-elapsed-test.XXXXXX")"
late_tick_temporary="$(mktemp -d "${TMPDIR:-/tmp}/sakuracord-late-tick-test.XXXXXX")"
missing_profiler_temporary="$(mktemp -d "${TMPDIR:-/tmp}/sakuracord-missing-profiler-test.XXXXXX")"
provenance_temporary="$(mktemp -d "${TMPDIR:-/tmp}/sakuracord-provenance-test.XXXXXX")"
source_marker="$root/.performance-provenance-test.$$"
trap 'rm -rf "$temporary" "$member_list_temporary" "$startup_temporary" "$insufficient_temporary" "$cancelled_temporary" "$missing_outcome_temporary" "$pagination_failed_temporary" "$short_distance_temporary" "$missing_elapsed_temporary" "$late_tick_temporary" "$missing_profiler_temporary" "$provenance_temporary"; rm -f "$source_marker"' EXIT

cp "$fixture"/* "$temporary"/
"$root/script/performance_benchmark.sh" summarize "$temporary" >/dev/null

summary="$temporary/summary.txt"
grep -F $'signpost.OverlappingWork.count\t2' "$summary" >/dev/null
grep -F $'signpost.OverlappingWork.median\t2000.000 ms' "$summary" >/dev/null
grep -F $'signpost.OverlappingWork.maximum\t3000.000 ms' "$summary" >/dev/null
grep -F $'measurement.window\tMessageTimelineAutoScrollBenchmark' "$summary" >/dev/null
grep -F $'resources.window\tMessageTimelineAutoScrollBenchmark nominal 20.000 s' "$summary" >/dev/null
grep -F $'duration.nominal\t20.0 s' "$summary" >/dev/null
grep -F $'duration.ui-stop\t20.0 s' "$summary" >/dev/null
grep -F $'duration.overshoot\t0.0 s' "$summary" >/dev/null
grep -F $'spatial.distance.completed\t192000.0 points' "$summary" >/dev/null
grep -F $'spatial.distance.nominal\t192000.0 points' "$summary" >/dev/null
grep -F $'spatial.distance.deficit\t0.0 points' "$summary" >/dev/null
grep -F $'spatial.quality\t1.0 ratio' "$summary" >/dev/null
grep -F $'cpu.average\t110.000 %' "$summary" >/dev/null
grep -F $'energy.average\t1.200 mW' "$summary" >/dev/null
grep -F $'energy.total\t24.000 mJ' "$summary" >/dev/null
grep -F $'physical-footprint.sampled.minimum\t200.000 MiB' "$summary" >/dev/null
grep -F $'physical-footprint.sampled.maximum\t203.000 MiB' "$summary" >/dev/null
if grep -E '^(rss\.|footprint\.current|footprint\.peak)' "$summary" >/dev/null; then
    printf '%s\n' 'exact resource fixture mislabeled physical footprint or reported outside-window footprint' >&2
    exit 1
fi
if grep -F 'signpost.OverlappingWork.unmatched' "$summary" >/dev/null; then
    printf '%s\n' 'overlap fixture produced unmatched signposts' >&2
    exit 1
fi

cp "$fixture"/* "$member_list_temporary"/
perl -0pi -e \
    's/scenario\tauthenticated-scroll/scenario\tauthenticated-member-list-scroll/; s/MessageTimelineAutoScrollBenchmark/MemberListAutoScrollBenchmark/g' \
    "$member_list_temporary/metadata.tsv" "$member_list_temporary/signposts.xml"
"$root/script/performance_benchmark.sh" summarize "$member_list_temporary" >/dev/null
member_list_summary="$member_list_temporary/summary.txt"
grep -F $'measurement.window\tMemberListAutoScrollBenchmark' \
    "$member_list_summary" >/dev/null
grep -F $'resources.window\tMemberListAutoScrollBenchmark nominal 20.000 s' \
    "$member_list_summary" >/dev/null
grep -F $'spatial.quality\t1.0 ratio' "$member_list_summary" >/dev/null

cp "$root/script/fixtures/performance-startup-order"/* "$startup_temporary"/
"$root/script/performance_benchmark.sh" summarize "$startup_temporary" >/dev/null
startup_summary="$startup_temporary/summary.txt"
grep -F $'measurement.window\tStartupToWorkspace' "$startup_summary" >/dev/null
grep -F $'resources.window\tnot applicable: startup uses signpost-bounded Time Profiler samples' \
    "$startup_summary" >/dev/null
grep -F $'startup.cpu-source\tTime Profiler samples in startup-time-profile.txt' \
    "$startup_summary" >/dev/null
grep -F $'window\t1.000000...5.000000 s' \
    "$startup_temporary/startup-time-profile.txt" >/dev/null
grep -F $'samples\t1' "$startup_temporary/startup-time-profile.txt" >/dev/null
if grep -E '^(cpu\.|energy\.|wakeups\.|rss\.|footprint\.)' "$startup_summary" >/dev/null; then
    printf '%s\n' 'startup fixture reported structurally partial process metrics' >&2
    exit 1
fi

cp "$root/script/fixtures/performance-startup-order"/* "$missing_profiler_temporary"/
rm "$missing_profiler_temporary/time-profile.xml"
if "$root/script/performance_benchmark.sh" summarize "$missing_profiler_temporary" >/dev/null 2>&1; then
    printf '%s\n' 'startup benchmark without Time Profiler data was accepted' >&2
    exit 1
fi

cp "$root/script/fixtures/performance-insufficient-history"/* "$insufficient_temporary"/
if "$root/script/performance_benchmark.sh" summarize "$insufficient_temporary" >/dev/null 2>&1; then
    printf '%s\n' 'insufficient-history benchmark was accepted as a complete workload' >&2
    exit 1
fi

cp "$root/script/fixtures/performance-cancelled"/* "$cancelled_temporary"/
if "$root/script/performance_benchmark.sh" summarize "$cancelled_temporary" >/dev/null 2>&1; then
    printf '%s\n' 'cancelled benchmark was accepted as a complete workload' >&2
    exit 1
fi

cp "$root/script/fixtures/performance-cancelled"/* "$missing_outcome_temporary"/
perl -0pi -e \
    's/MessageTimelineAutoScrollBenchmarkCancelled/UnrelatedBenchmarkEvent/g' \
    "$missing_outcome_temporary/signposts.xml"
if "$root/script/performance_benchmark.sh" summarize "$missing_outcome_temporary" >/dev/null 2>&1; then
    printf '%s\n' 'benchmark without an explicit completion outcome was accepted' >&2
    exit 1
fi

cp "$fixture"/* "$pagination_failed_temporary"/
perl -0pi -e \
    's/MessageTimelineAutoScrollBenchmarkCompleted/MessageTimelineAutoScrollBenchmarkPaginationFailed/g' \
    "$pagination_failed_temporary/signposts.xml"
perl -0pi -e 's/outcome\tcompleted/outcome\tpaginationFailed/' \
    "$pagination_failed_temporary/benchmark-result.tsv"
if "$root/script/performance_benchmark.sh" summarize "$pagination_failed_temporary" >/dev/null 2>&1; then
    printf '%s\n' 'pagination-failed benchmark was accepted as complete' >&2
    exit 1
fi

cp "$fixture"/* "$short_distance_temporary"/
perl -0pi -e \
    's/completed_distance_points\t192000\.0/completed_distance_points\t191360.0/; s/distance_deficit_points\t0\.0/distance_deficit_points\t640.0/; s/spatial_quality_ratio\t1\.0/spatial_quality_ratio\t0.9966666666666667/' \
    "$short_distance_temporary/benchmark-result.tsv"
"$root/script/performance_benchmark.sh" summarize "$short_distance_temporary" >/dev/null
short_summary="$short_distance_temporary/summary.txt"
grep -F $'spatial.distance.completed\t191360.0 points' "$short_summary" >/dev/null
grep -F $'spatial.distance.deficit\t640.0 points' "$short_summary" >/dev/null
grep -F $'spatial.quality\t0.9966666666666667 ratio' "$short_summary" >/dev/null

cp "$fixture"/* "$missing_elapsed_temporary"/
perl -ni -e 'print unless /^elapsed_seconds\t/' \
    "$missing_elapsed_temporary/benchmark-result.tsv"
if "$root/script/performance_benchmark.sh" summarize "$missing_elapsed_temporary" >/dev/null 2>&1; then
    printf '%s\n' 'benchmark without finite elapsed seconds was accepted' >&2
    exit 1
fi

cp "$fixture"/* "$late_tick_temporary"/
perl -0pi -e \
    's/elapsed_seconds\t20\.0/elapsed_seconds\t23.0/; s/elapsed_overshoot_seconds\t0\.0/elapsed_overshoot_seconds\t3.0/' \
    "$late_tick_temporary/benchmark-result.tsv"
perl -0pi -e \
    's/00:21\.000\.000/00:24.000.000/g; s/>21000000000</>24000000000</g' \
    "$late_tick_temporary/signposts.xml"
"$root/script/performance_benchmark.sh" summarize "$late_tick_temporary" >/dev/null
late_summary="$late_tick_temporary/summary.txt"
grep -F $'duration.nominal\t20.0 s' "$late_summary" >/dev/null
grep -F $'duration.ui-stop\t23.0 s' "$late_summary" >/dev/null
grep -F $'duration.overshoot\t3.0 s' "$late_summary" >/dev/null
grep -F $'resources.window\tMessageTimelineAutoScrollBenchmark nominal 20.000 s' "$late_summary" >/dev/null

provenance_executable="$provenance_temporary/SakuraCord"
provenance_directory="$provenance_temporary/build-provenance"
printf '%s\n' 'synthetic benchmark executable' >"$provenance_executable"
SAKURACORD_PERFORMANCE_EXECUTABLE_OVERRIDE="$provenance_executable" \
SAKURACORD_PERFORMANCE_PROVENANCE_DIRECTORY_OVERRIDE="$provenance_directory" \
    "$root/script/performance_benchmark.sh" provenance-record >/dev/null
SAKURACORD_PERFORMANCE_EXECUTABLE_OVERRIDE="$provenance_executable" \
SAKURACORD_PERFORMANCE_PROVENANCE_DIRECTORY_OVERRIDE="$provenance_directory" \
    "$root/script/performance_benchmark.sh" provenance-check
printf '%s\n' 'source changed after build' >"$source_marker"
if SAKURACORD_PERFORMANCE_EXECUTABLE_OVERRIDE="$provenance_executable" \
    SAKURACORD_PERFORMANCE_PROVENANCE_DIRECTORY_OVERRIDE="$provenance_directory" \
    "$root/script/performance_benchmark.sh" provenance-check >/dev/null 2>&1; then
    printf '%s\n' 'benchmark accepted source changes made after the executable build' >&2
    exit 1
fi
rm "$source_marker"

printf '%s\n' 'Performance benchmark parser tests passed.'
