#!/usr/bin/env python3
"""Analyze SakuraCord side-chat motion benchmark recordings.

Input is one or more JSON recordings written by the in-app motion benchmark
(schema ``sakuracord-motion-benchmark/1``). Each recording is analyzed on its own
(times are per process) and the per-action results are pooled for the grouped
report, ``--json``, ``--html`` and ``--compare`` outputs.

Per action (window = action time to the next action, or the last frame):

* Settle: the first frame, at or after the first moving frame, from which every
  probe component stays within 0.5 pt for 0.25 s. The last frame of that stable
  run is the "settled frame" used for reference and layout comparisons.
* Motion: frames from the first frame whose moving edge differs from its
  pre-action value by more than 0.5 pt (or whose probe appears or disappears)
  until the settle. The edge is normalized to progress (0 = start, 1 = settled).
* Ideal spring: SwiftUI ``Spring(duration: d, bounce: 0)`` is critically damped,
  ``p(t) = 1 - (1 + wt) e^(-wt)`` with ``w = 2 pi / d``. The start time t0 in
  [action, first moving frame] is fitted on a 1 ms grid (least squares).
  ``max_position_error_pt`` is the largest |observed - ideal| progress times the
  travel; ``jump_frames`` counts steps over 1.5 pt and over 1.5x the ideal step for
  the same frame interval; ``backward_steps`` counts reversals over 0.5 pt.
* Snaps: ``start_snap_pt`` is the first step minus the ideal step; ``end_snap_pt``
  is the step into the first frame at the settled value minus its ideal step.
* Pacing: intervals between consecutive frame timestamps over
  [action, max(settle, action + 0.6 s)]. A late frame is an interval over 1.5x
  the refresh interval; dropped frames are ``round(interval / refresh) - 1``.
* Layout: gap between the trailing probe (pane or members) and the primary
  probe, and the toolbar title offset from the pane, compared with their settled
  values; toolbar signature changes; timeline scroll jumps (distance from bottom
  changing while the document height does not); main-thread busy periods.
* Idle: stretches more than 1 s after an action settles and before the next
  action, plus any explicit ``idle`` windows in the recording.
"""

from __future__ import annotations

import argparse
import bisect
import html
import json
import math
import statistics
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

RECORDING_SCHEMA = "sakuracord-motion-benchmark/1"
ANALYSIS_SCHEMA = "sakuracord-motion-benchmark-analysis/1"

EDGE_TOLERANCE_PT = 0.5
SETTLE_HOLD_S = 0.25
MIN_PACING_WINDOW_S = 0.6
LATE_FACTOR = 1.5
JUMP_FACTOR = 1.5
JUMP_MIN_PT = 1.5
BACKWARD_MIN_PT = 0.5
IDLE_MARGIN_S = 1.0
CONTENT_TAIL_S = 0.3
CONTENT_JUMP_PT = 2.0
DOCUMENT_HEIGHT_TOLERANCE_PT = 0.5
MAX_FIT_CANDIDATES = 5000
TRAILING_PROBES = ("pane", "members")
AUTO_IDLE_LABEL = "auto"

Rect = tuple[float, float, float, float]

# (analysis key, report label, transform applied before grouping)
GROUP_METRICS: list[tuple[str, str, Callable[[float], float]]] = [
    ("first_motion_latency_ms", "latency ms", float),
    ("motion_late_frames", "late frames during motion", float),
    ("motion_worst_interval_ms", "worst interval during motion ms", float),
    ("late_frames", "late frames", float),
    ("dropped_frames", "dropped frames", float),
    ("interval_max_ms", "worst interval ms", float),
    ("hitch_excess_ms", "hitch excess ms", float),
    ("visible_motion_ratio", "visible motion ratio", float),
    ("max_step_fraction", "largest step (of travel)", float),
    ("max_lag_pt", "max lag behind spring pt", float),
    ("max_position_error_pt", "max fitted error pt", float),
    ("jump_frames", "jump frames", float),
    ("start_snap_pt", "start snap pt", float),
    ("end_snap_pt", "end snap pt", float),
    ("reference_mismatch_pt", "reference mismatch pt", float),
    ("max_gap_deviation_pt", "gap deviation pt", float),
    ("max_title_drift_pt", "title drift pt", float),
    ("toolbar_changes_in_motion", "toolbar changes in motion", float),
    ("conversation_edge_jump_pt", "visible conversation edge jump pt", float),
    ("timeline_redraw_frames", "frames with timeline redraws in motion", float),
    ("content_jumps", "content jumps", float),
    ("final_distance_from_bottom_pt", "final distance from bottom pt", abs),
]


# --------------------------------------------------------------------------
# Recording model
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Frame:
    time: float
    probes: dict[str, Rect]
    timelines: list[dict[str, Any]]
    toolbar: int | None


@dataclass(frozen=True)
class Action:
    id: int
    name: str
    cycle: int
    time: float
    variant: str
    moving_probe: str | None
    edge: str | None

    @property
    def group(self) -> str:
        return f"{self.name} [{self.variant}]" if self.variant else self.name


@dataclass
class Recording:
    path: str
    configuration: str
    refresh_s: float
    scenario: dict[str, Any]
    spring: dict[str, Any]
    actions: list[Action]
    frames: list[Frame]
    times: list[float]
    busy: list[tuple[float, float]]
    references: dict[str, dict[str, Rect]]
    idle_windows: list[tuple[float, float, str]]
    signatures: list[str]

    @property
    def spring_duration_s(self) -> float:
        return float(self.spring.get("durationS", 0.24))

    @property
    def late_limit_s(self) -> float:
        return LATE_FACTOR * self.refresh_s


def parse_rect(values: Any) -> Rect:
    x, y, w, h = (float(v) for v in values)
    return (x, y, w, h)


def parse_recording(data: dict[str, Any], path: str = "<memory>") -> Recording:
    if data.get("schema") != RECORDING_SCHEMA:
        print(
            f"warning: {path}: schema {data.get('schema')!r}, expected {RECORDING_SCHEMA!r}",
            file=sys.stderr,
        )
    frames = sorted(
        (
            Frame(
                time=float(raw["time"]),
                probes={k: parse_rect(v) for k, v in raw.get("probes", {}).items()},
                timelines=list(raw.get("timelines", [])),
                toolbar=raw.get("toolbar"),
            )
            for raw in data.get("frames", [])
        ),
        key=lambda f: f.time,
    )
    actions = sorted(
        (
            Action(
                id=int(raw.get("id", i)),
                name=str(raw["name"]),
                cycle=int(raw.get("cycle", 0)),
                time=float(raw["time"]),
                variant=str(raw.get("variant") or ""),
                moving_probe=raw.get("movingProbe"),
                edge=raw.get("edge"),
            )
            for i, raw in enumerate(data.get("actions", []))
        ),
        key=lambda a: a.time,
    )
    references = {
        name: {k: parse_rect(v) for k, v in (ref or {}).get("probes", {}).items()}
        for name, ref in (data.get("references") or {}).items()
    }
    return Recording(
        path=path,
        configuration=str(data.get("configuration", "unknown")),
        refresh_s=float(data.get("refreshIntervalMS", 16.67)) / 1000.0,
        scenario=dict(data.get("scenario") or {}),
        spring=dict(data.get("spring") or {}),
        actions=actions,
        frames=frames,
        times=[f.time for f in frames],
        busy=[
            (float(b["start"]), float(b["durationMS"]))
            for b in data.get("mainThreadBusy", [])
        ],
        references=references,
        idle_windows=[
            (float(w["start"]), float(w["end"]), str(w.get("label") or "idle"))
            for w in data.get("idle", [])
        ],
        signatures=list(data.get("toolbarSignatures", [])),
    )


# --------------------------------------------------------------------------
# Small numeric helpers
# --------------------------------------------------------------------------


def percentile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * q
    low, high = math.floor(position), math.ceil(position)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def edge_of(rect: Rect | None, edge: str | None) -> float | None:
    if rect is None:
        return None
    if edge == "minX":
        return rect[0]
    if edge == "maxX":
        return rect[0] + rect[2]
    if edge == "width":
        return rect[2]
    raise ValueError(f"unknown edge {edge!r}")


def spring_time_at(progress: float, omega: float) -> float:
    """Inverse of spring_progress by bisection."""
    low, high = 0.0, 50.0 / omega
    for _ in range(60):
        middle = (low + high) / 2
        if spring_progress(middle, omega) < progress:
            low = middle
        else:
            high = middle
    return (low + high) / 2


def spring_progress(t: float, omega: float) -> float:
    """Progress of a critically damped spring after t seconds (0 for t <= 0)."""
    if t <= 0:
        return 0.0
    x = omega * t
    return 1.0 - (1.0 + x) * math.exp(-x)


def max_rect_difference(
    a: dict[str, Rect], b: dict[str, Rect]
) -> tuple[float | None, list[str]]:
    """Largest component difference over shared probes, and probes present in only one."""
    shared = a.keys() & b.keys()
    worst = max(
        (abs(x - y) for key in shared for x, y in zip(a[key], b[key])), default=None
    )
    return worst, sorted(a.keys() ^ b.keys())


def maximum(values: list[float]) -> float | None:
    return max(values) if values else None


def round_or_none(value: float | None, digits: int = 3) -> float | None:
    return None if value is None else round(value, digits)


# --------------------------------------------------------------------------
# Motion location
# --------------------------------------------------------------------------


@dataclass
class Location:
    """Frame indices describing one action window."""

    start: int  # first frame at or after the action
    end: int  # exclusive; first frame of the next action window
    pre: int | None  # last frame before the action
    pre_value: float | None = None
    first_move: int | None = None
    settle: int | None = None  # first frame of the stable run
    settled: int | None = None  # last frame of the stable run
    did_settle: bool = False


def find_first_move(rec: Recording, action: Action, loc: Location) -> None:
    if action.moving_probe is None or action.edge is None:
        return
    frames = rec.frames
    reference = loc.pre if loc.pre is not None else loc.start
    loc.pre_value = edge_of(frames[reference].probes.get(action.moving_probe), action.edge)
    scan_from = loc.start if loc.pre is not None else loc.start + 1
    for i in range(scan_from, loc.end):
        value = edge_of(frames[i].probes.get(action.moving_probe), action.edge)
        if (value is None) != (loc.pre_value is None) or (
            value is not None and abs(value - loc.pre_value) > EDGE_TOLERANCE_PT
        ):
            loc.first_move = i
            return


def find_settle(rec: Recording, action: Action, loc: Location) -> None:
    """Earliest frame after which the moving edge stays at its final value.

    The final value is the last frame before the next action. A stall is not
    stability: every later frame must match, so a frozen first frame followed
    by a jump to the end state is never mistaken for a settled animation.
    The last frame of the window is the settled layout compared with the
    static reference.
    """
    frames = rec.frames
    assert loc.first_move is not None
    final = edge_of(frames[loc.end - 1].probes.get(action.moving_probe), action.edge)
    settle = loc.end - 1
    for i in range(loc.end - 1, loc.first_move - 1, -1):
        value = edge_of(frames[i].probes.get(action.moving_probe), action.edge)
        if (value is None) != (final is None) or (
            value is not None and abs(value - final) > EDGE_TOLERANCE_PT
        ):
            break
        settle = i
    loc.settle, loc.settled = settle, loc.end - 1
    loc.did_settle = frames[loc.end - 1].time - frames[settle].time >= SETTLE_HOLD_S


def content_max_x(rec: Recording, loc: Location) -> float | None:
    """Right edge of the content area: the widest primary probe around the action."""
    indices = list(range(loc.start, loc.end))
    if loc.pre is not None:
        indices.append(loc.pre)
    primaries = [
        rec.frames[i].probes["primary"][0] + rec.frames[i].probes["primary"][2]
        for i in indices
        if "primary" in rec.frames[i].probes
    ]
    if primaries:
        return max(primaries)
    everything = [
        r[0] + r[2] for i in indices for r in rec.frames[i].probes.values()
    ]
    return max(everything, default=None)


OPPOSITE_TOKENS = {
    "open": "close",
    "close": "open",
    "show": "hide",
    "hide": "show",
    "on": "off",
    "off": "on",
    "enter": "exit",
    "exit": "enter",
}


def opposite_name(name: str) -> str:
    return "-".join(OPPOSITE_TOKENS.get(token, token) for token in name.split("-"))


def reference_for(rec: Recording, action: Action) -> dict[str, Rect] | None:
    """The action's static reference: its variant's own, if captured."""
    return rec.references.get(action.group) or rec.references.get(action.name)


def estimate_start_edge(
    rec: Recording, index: int, content_max: float | None
) -> tuple[float | None, str]:
    """Pre-action edge for a probe that was not on screen before the action."""
    action = rec.actions[index]
    probe, edge = action.moving_probe, action.edge
    candidates = [rec.references.get(opposite_name(action.name))]
    if index > 0:
        candidates.append(reference_for(rec, rec.actions[index - 1]))
    for reference in candidates:
        if reference and probe in reference:
            return edge_of(reference[probe], edge), "reference"
    return offscreen_edge(edge, content_max), "offscreen"


def offscreen_edge(edge: str | None, content_max: float | None) -> float | None:
    if edge == "width":
        return 0.0
    return content_max


# --------------------------------------------------------------------------
# Per-metric analyses
# --------------------------------------------------------------------------


def pacing_metrics(rec: Recording, action: Action, start: int, last: int) -> dict[str, Any]:
    refresh_ms = rec.refresh_s * 1000.0
    late_limit_ms = rec.late_limit_s * 1000.0
    intervals = [
        (
            (rec.frames[i].time - action.time) * 1000.0,
            (rec.frames[i].time - rec.frames[i - 1].time) * 1000.0,
        )
        for i in range(max(start, 1), last + 1)
    ]
    values = [interval for _, interval in intervals]
    late = [(offset, interval) for offset, interval in intervals if interval > late_limit_ms]
    return {
        "interval_p50_ms": round_or_none(percentile(values, 0.5)),
        "interval_p95_ms": round_or_none(percentile(values, 0.95)),
        "interval_max_ms": round_or_none(maximum(values)),
        "late_frames": len(late),
        "dropped_frames": sum(
            max(0, int(interval / refresh_ms + 0.5) - 1) for interval in values
        ),
        "hitches": [
            {"offset_ms": round(offset, 3), "interval_ms": round(interval, 3)}
            for offset, interval in late
        ],
        "hitch_excess_ms": round(sum(i - refresh_ms for _, i in late), 3),
        "intervals": [[round(o, 2), round(i, 3)] for o, i in intervals],
    }


def motion_pacing_metrics(rec: Recording, loc: Location) -> dict[str, Any]:
    """Pacing of the frames that show the motion itself.

    The interval into the first moving frame is the response to the action
    (`first_motion_latency_ms`); frames after the settle are the static
    layout. Late frames between them interrupt the motion the reader sees.
    """
    if loc.first_move is None or loc.settle is None:
        return {"motion_late_frames": None, "motion_worst_interval_ms": None}
    intervals = [
        (rec.frames[i].time - rec.frames[i - 1].time) * 1000.0
        for i in range(loc.first_move + 1, loc.settle + 1)
    ]
    limit = rec.late_limit_s * 1000.0
    return {
        "motion_late_frames": sum(1 for interval in intervals if interval > limit),
        "motion_worst_interval_ms": round_or_none(maximum(intervals)),
    }


def busy_metrics(rec: Recording, lo: float, hi: float) -> dict[str, Any]:
    durations = [d for start, d in rec.busy if lo <= start <= hi]
    return {
        "main_thread_busy_max_ms": round_or_none(maximum(durations)) or 0.0,
        "main_thread_busy_total_ms": round(sum(durations), 3),
    }


def fit_spring_start(
    points: list[tuple[int, float, float, float]], lo: float, hi: float, omega: float
) -> float:
    """Start time in [lo, hi] (1 ms grid) minimizing squared progress error."""
    count = max(1, min(MAX_FIT_CANDIDATES, int((hi - lo) * 1000.0)))
    best_t0, best_error = lo, math.inf
    for k in range(count + 1):
        t0 = lo + (hi - lo) * k / count
        error = sum((p - spring_progress(t - t0, omega)) ** 2 for _, t, _, p in points)
        if error < best_error:
            best_t0, best_error = t0, error
    return best_t0


def motion_metrics(
    rec: Recording, index: int, loc: Location, content_max: float | None
) -> dict[str, Any]:
    action = rec.actions[index]
    frames = rec.frames
    assert loc.first_move is not None and loc.settled is not None and loc.settle is not None
    probe, edge = action.moving_probe, action.edge
    first_time = frames[loc.first_move].time
    result: dict[str, Any] = {
        "first_motion_latency_ms": round((first_time - action.time) * 1000.0, 3),
        "settle_ms": round((frames[loc.settle].time - action.time) * 1000.0, 3),
        "settled": loc.did_settle,
    }

    settled_value = edge_of(frames[loc.settled].probes.get(probe), edge)
    removed = settled_value is None
    appearing = loc.pre_value is None
    start_value, end_value = loc.pre_value, settled_value
    result["start_value_source"] = "frame"
    if appearing:
        start_value, result["start_value_source"] = estimate_start_edge(rec, index, content_max)
    if removed:
        end_value = offscreen_edge(edge, content_max)
    result["appearing"], result["removed"] = appearing, removed
    if start_value is None or end_value is None:
        return result
    travel = abs(end_value - start_value)
    result["travel_pt"] = round(travel, 3)

    observed: list[tuple[int, float, float, float]] = []  # index, time, value, progress
    for i in range(loc.first_move, loc.settle + 1):
        value = edge_of(frames[i].probes.get(probe), edge)
        if value is not None and travel > EDGE_TOLERANCE_PT:
            observed.append((i, frames[i].time, value, (value - start_value) / (end_value - start_value)))
    result["motion_frames"] = len(observed)
    if not observed:
        result["motion_duration_ms"] = 0.0
        return result

    # Arrival: first frame at the settled value (last present frame if the probe goes away).
    arrival = observed[-1]
    if not removed:
        arrival = next(
            (o for o in observed if abs(o[2] - end_value) <= EDGE_TOLERANCE_PT), arrival
        )
    result["motion_duration_ms"] = round((arrival[1] - first_time) * 1000.0, 3)

    omega = 2.0 * math.pi / rec.spring_duration_s
    t0 = fit_spring_start(observed, action.time, observed[0][1], omega)
    result["start_delay_ms"] = round((t0 - action.time) * 1000.0, 3)

    errors = [abs(p - spring_progress(t - t0, omega)) for _, t, _, p in observed]
    result["max_progress_error"] = round(max(errors), 5)
    result["max_position_error_pt"] = round(max(errors) * travel, 3)

    direction = 1.0 if end_value >= start_value else -1.0
    prior_time = frames[loc.first_move - 1].time if loc.first_move > 0 else action.time
    prior_value = start_value
    late_limit = rec.late_limit_s
    steps_fraction: list[float] = []
    jump_frames = backward = 0
    curve: list[list[float]] = []
    snaps: dict[int, float] = {}
    for i, t, value, progress in observed:
        step_pt = abs(value - prior_value)
        ideal_pt = (
            spring_progress(t - t0, omega) - spring_progress(prior_time - t0, omega)
        ) * travel
        steps_fraction.append(step_pt / travel)
        if step_pt > JUMP_MIN_PT and step_pt > JUMP_FACTOR * ideal_pt:
            jump_frames += 1
        if (value - prior_value) * direction < -BACKWARD_MIN_PT:
            backward += 1
        snaps[i] = max(0.0, step_pt - ideal_pt)
        late = i > 0 and t - frames[i - 1].time > late_limit
        curve.append([round((t - action.time) * 1000.0, 2), round(progress, 5), int(late)])
        prior_time, prior_value = t, value
    # What the reader sees: in-between frames shown, against the ideal number
    # of display refreshes the spring spends between 2% and 98% progress, and
    # the largest distance behind a spring that starts on the next refresh.
    intermediate = sum(1 for o in observed if 0.02 < abs(o[3]) < 0.98)
    ideal_span = spring_time_at(0.98, omega) - spring_time_at(0.02, omega)
    ideal_intermediate = max(1, round(ideal_span / rec.refresh_s))
    expected_start = action.time + rec.refresh_s
    lag = max(
        abs(spring_progress(t - expected_start, omega) - p) * travel for _, t, _, p in observed
    )
    result.update(
        {
            "intermediate_frames": intermediate,
            "ideal_intermediate_frames": ideal_intermediate,
            "visible_motion_ratio": round(min(1.0, intermediate / ideal_intermediate), 3),
            "max_lag_pt": round(lag, 3),
            "max_step_fraction": round(max(steps_fraction), 5),
            "jump_frames": jump_frames,
            "backward_steps": backward,
            "start_snap_pt": round(snaps[observed[0][0]], 3),
            "end_snap_pt": None if removed else round(snaps[arrival[0]], 3),
            "curve": curve,
        }
    )
    return result


def reference_metrics(rec: Recording, index: int, loc: Location) -> dict[str, Any]:
    action = rec.actions[index]
    result: dict[str, Any] = {
        "reference_mismatch_pt": None,
        "reference_presence_mismatches": [],
        "start_reference_mismatch_pt": None,
    }
    if loc.settled is not None:
        reference = reference_for(rec, action)
        if reference is not None:
            worst, presence = max_rect_difference(rec.frames[loc.settled].probes, reference)
            result["reference_mismatch_pt"] = round_or_none(worst if worst is not None else 0.0)
            result["reference_presence_mismatches"] = presence
    previous = reference_for(rec, rec.actions[index - 1]) if index > 0 else None
    if previous is not None and loc.pre is not None:
        worst, _ = max_rect_difference(rec.frames[loc.pre].probes, previous)
        result["start_reference_mismatch_pt"] = round_or_none(worst if worst is not None else 0.0)
    return result


def layout_metrics(rec: Recording, action: Action, loc: Location) -> dict[str, Any]:
    result: dict[str, Any] = {
        "max_gap_deviation_pt": None,
        "max_title_drift_pt": None,
        "title_appear_offset_ms": None,
    }
    assert loc.first_move is not None and loc.settle is not None and loc.settled is not None
    frames = rec.frames
    motion = range(loc.first_move, loc.settle + 1)
    rest_frames = [loc.settled] + ([loc.pre] if loc.pre is not None else [])

    trailing = action.moving_probe if action.moving_probe in TRAILING_PROBES else None
    if trailing is None:
        trailing = next(
            (
                name
                for name in TRAILING_PROBES
                if any(name in frames[i].probes for i in [*motion, *rest_frames])
            ),
            None,
        )

    def gap(frame: Frame) -> float | None:
        if trailing in frame.probes and "primary" in frame.probes:
            return frame.probes[trailing][0] - (
                frame.probes["primary"][0] + frame.probes["primary"][2]
            )
        return None

    def title_offset(frame: Frame) -> float | None:
        if "toolbarTitle" in frame.probes and "pane" in frame.probes:
            return frame.probes["toolbarTitle"][0] - frame.probes["pane"][0]
        return None

    def deviation(measure: Callable[[Frame], float | None]) -> float | None:
        rest = next(
            (v for v in (measure(frames[i]) for i in rest_frames) if v is not None), None
        )
        if rest is None:
            return None
        values = [abs(v - rest) for v in (measure(frames[i]) for i in motion) if v is not None]
        return round_or_none(maximum(values))

    if trailing is not None:
        result["max_gap_deviation_pt"] = deviation(gap)
    result["max_title_drift_pt"] = deviation(title_offset)

    pre_has_title = loc.pre is not None and "toolbarTitle" in frames[loc.pre].probes
    if not pre_has_title:
        first_title = next(
            (i for i in range(loc.start, loc.end) if "toolbarTitle" in frames[i].probes), None
        )
        if first_title is not None:
            result["title_appear_offset_ms"] = round(
                (frames[first_title].time - frames[loc.first_move].time) * 1000.0, 3
            )
    return result


def visibility_metrics(rec: Recording, loc: Location) -> dict[str, Any]:
    """What the reader sees of the conversation and the timelines' reflows.

    `conversation_edge_jump_pt` is the largest frame-to-frame jump of the
    conversation's visible trailing edge that the column covering it did not
    make too: the conversation's own edge, or the covering column's leading
    edge where a pane or the member list lies over it. Narrowing beneath an
    arrived pane or widening beneath a departing one is hidden and scores 0;
    narrowing while the arriving pane is still offscreen does not.
    """
    frames = rec.frames[loc.start - 1 if loc.start > 0 else 0 : loc.end]

    def cover_edge(frame: Frame) -> float | None:
        primary = frame.probes.get("primary")
        if primary is None:
            return None
        edges = [
            frame.probes[name][0]
            for name in TRAILING_PROBES
            if name in frame.probes and frame.probes[name][0] > primary[0] + 1
        ]
        return min(edges) if edges else None

    def visible_edge(frame: Frame) -> float | None:
        primary = frame.probes.get("primary")
        if primary is None:
            return None
        edge = primary[0] + primary[2]
        cover = cover_edge(frame)
        return edge if cover is None else min(edge, cover)

    jump = 0.0
    for previous, frame in zip(frames, frames[1:]):
        before, after = visible_edge(previous), visible_edge(frame)
        if before is not None and after is not None:
            cover_before, cover_after = cover_edge(previous), cover_edge(frame)
            covered = (
                cover_before is not None and cover_after is not None
                and before == cover_before and after == cover_after
            )
            if not covered:
                jump = max(jump, abs(after - before))
    return {"conversation_edge_jump_pt": round(jump, 3)}


def redraw_metrics(rec: Recording, loc: Location) -> dict[str, Any]:
    """Frames during the motion in which a timeline drew again.

    A column that only moves needs no drawing; a redraw on every frame means
    a timeline is reacting to the motion (hover under a still pointer, a
    viewport change) and costs main-thread time per frame.
    """
    if loc.first_move is None or loc.settle is None:
        return {"timeline_redraw_frames": None}
    frames = rec.frames[loc.first_move : loc.settle + 1]

    def draws(frame: Frame) -> int:
        return sum(int(timeline.get("draws", 0)) for timeline in frame.timelines)

    count = sum(
        1
        for previous, frame in zip(frames, frames[1:])
        if len(previous.timelines) == len(frame.timelines) and draws(frame) > draws(previous)
    )
    return {"timeline_redraw_frames": count}


def toolbar_metrics(rec: Recording, action: Action, loc: Location, motion: tuple[float, float] | None) -> dict[str, Any]:
    previous = rec.frames[loc.pre].toolbar if loc.pre is not None else None
    changes = []
    for i in range(loc.start, loc.end):
        current = rec.frames[i].toolbar
        if current is None:
            continue
        if previous is not None and current != previous:
            t = rec.frames[i].time
            changes.append(
                {
                    "offset_ms": round((t - action.time) * 1000.0, 3),
                    "from": previous,
                    "to": current,
                    "during_motion": motion is not None and motion[0] <= t <= motion[1],
                }
            )
        previous = current
    return {
        "toolbar_changes": changes,
        "toolbar_changes_in_motion": sum(c["during_motion"] for c in changes),
    }


def timeline_metrics(rec: Recording, action: Action, loc: Location, settle_time: float | None) -> dict[str, Any]:
    result: dict[str, Any] = {
        "content_jumps": None,
        "final_distance_from_bottom_pt": None,
        "rows_ready_ms": None,
    }
    region = action.moving_probe
    if region is None or settle_time is None:
        return result
    frames = rec.frames
    limit = min(settle_time + CONTENT_TAIL_S, rec.times[loc.end - 1])
    # Region timelines per frame: {timeline index: timeline}, for timelines centered in the region.
    series: list[tuple[int, dict[int, dict[str, Any]]]] = []
    for i in range(loc.start, loc.end):
        if frames[i].time > limit:
            break
        rect = frames[i].probes.get(region)
        if rect is None:
            continue
        inside = {}
        for ti, timeline in enumerate(frames[i].timelines):
            x, y, w, h = parse_rect(timeline["frame"])
            cx, cy = x + w / 2.0, y + h / 2.0
            if rect[0] - 1 <= cx <= rect[0] + rect[2] + 1 and rect[1] - 1 <= cy <= rect[1] + rect[3] + 1:
                inside[ti] = timeline
        if inside:
            series.append((i, inside))
    if not series:
        return result

    ready = next(
        (i for i, tls in series if any(tl.get("rows", 0) > 0 for tl in tls.values())), None
    )
    jump_frames: set[int] = set()
    if ready is not None:
        result["rows_ready_ms"] = round((frames[ready].time - action.time) * 1000.0, 3)
        previous: dict[int, dict[str, Any]] = {}
        for i, tls in series:
            for ti, timeline in tls.items():
                before = previous.get(ti)
                if i >= ready and before is not None:
                    changed = abs(timeline["distanceFromBottom"] - before["distanceFromBottom"])
                    height = abs(timeline["documentHeight"] - before["documentHeight"])
                    if changed > CONTENT_JUMP_PT and height <= DOCUMENT_HEIGHT_TOLERANCE_PT:
                        jump_frames.add(i)
            previous = tls
    result["content_jumps"] = len(jump_frames)

    last_index, last_timelines = series[-1]
    if frames[last_index].time >= settle_time:
        result["final_distance_from_bottom_pt"] = round(
            max(
                (tl["distanceFromBottom"] for tl in last_timelines.values()), key=abs
            ),
            3,
        )
    return result


# --------------------------------------------------------------------------
# Per-action and per-recording analysis
# --------------------------------------------------------------------------

NULL_MOTION_KEYS = [
    "first_motion_latency_ms", "motion_duration_ms", "settle_ms", "start_delay_ms",
    "max_progress_error", "max_position_error_pt", "max_step_fraction", "jump_frames",
    "backward_steps", "travel_pt", "start_snap_pt", "end_snap_pt", "reference_mismatch_pt",
    "start_reference_mismatch_pt", "max_gap_deviation_pt", "max_title_drift_pt",
    "title_appear_offset_ms", "content_jumps", "final_distance_from_bottom_pt",
    "rows_ready_ms", "motion_frames", "curve", "intermediate_frames",
    "motion_late_frames", "motion_worst_interval_ms",
    "ideal_intermediate_frames", "visible_motion_ratio", "max_lag_pt",
]


def analyze_action(rec: Recording, index: int) -> dict[str, Any]:
    action = rec.actions[index]
    window_end_time = rec.actions[index + 1].time if index + 1 < len(rec.actions) else None
    start = bisect.bisect_left(rec.times, action.time)
    end = len(rec.frames) if window_end_time is None else bisect.bisect_left(rec.times, window_end_time)
    loc = Location(start=start, end=end, pre=start - 1 if start > 0 else None)

    result: dict[str, Any] = {
        "id": action.id,
        "name": action.name,
        "variant": action.variant,
        "group": action.group,
        "cycle": action.cycle,
        "time": action.time,
        "moving_probe": action.moving_probe,
        "edge": action.edge,
        "moved": False,
        "settled": False,
        **dict.fromkeys(NULL_MOTION_KEYS),
        "reference_presence_mismatches": [],
        "toolbar_changes": [],
        "toolbar_changes_in_motion": 0,
        "hitches": [],
    }
    if end <= start:
        result.update(settle_time=action.time, late_frames=0, dropped_frames=0, hitch_excess_ms=0.0)
        return result

    find_first_move(rec, action, loc)
    motion_range: tuple[float, float] | None = None
    settle_time: float | None = None
    if loc.first_move is not None:
        find_settle(rec, action, loc)
        assert loc.settle is not None
        settle_time = rec.frames[loc.settle].time
        motion_range = (rec.frames[loc.first_move].time, settle_time)
        result["moved"] = True
        result.update(motion_metrics(rec, index, loc, content_max_x(rec, loc)))
        result.update(layout_metrics(rec, action, loc))
        result.update(reference_metrics(rec, index, loc))
    result.update(timeline_metrics(rec, action, loc, settle_time))
    result.update(toolbar_metrics(rec, action, loc, motion_range))
    result.update(visibility_metrics(rec, loc))
    result.update(redraw_metrics(rec, loc))

    pacing_end = max(settle_time or 0.0, action.time + MIN_PACING_WINDOW_S)
    last = min(bisect.bisect_right(rec.times, pacing_end), end) - 1
    result["settle_time"] = settle_time if settle_time is not None else action.time + MIN_PACING_WINDOW_S
    result["pacing_end_time"] = pacing_end
    result.update(pacing_metrics(rec, action, start, last))
    result.update(motion_pacing_metrics(rec, loc))
    result.update(busy_metrics(rec, action.time, pacing_end))
    return result


def idle_stretches(rec: Recording, results: list[dict[str, Any]]) -> list[tuple[float, float, str]]:
    stretches = list(rec.idle_windows)
    last_time = rec.times[-1] if rec.times else 0.0
    for i, result in enumerate(results):
        begin = result["settle_time"] + IDLE_MARGIN_S
        stop = rec.actions[i + 1].time if i + 1 < len(rec.actions) else last_time
        if stop > begin:
            stretches.append((begin, stop, AUTO_IDLE_LABEL))
    return stretches


def collect_idle(rec: Recording, results: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """Raw idle samples per label for pooling: duration, intervals and late count."""
    raw: dict[str, dict[str, Any]] = {}
    late_limit_ms = rec.late_limit_s * 1000.0
    for lo, hi, label in idle_stretches(rec, results):
        first = bisect.bisect_left(rec.times, lo)
        last = bisect.bisect_right(rec.times, hi)
        times = rec.times[first:last]
        if len(times) < 2:
            continue
        intervals = [(b - a) * 1000.0 for a, b in zip(times, times[1:])]
        entry = raw.setdefault(
            label, {"windows": 0, "duration_s": 0.0, "intervals_ms": [], "late_frames": 0}
        )
        entry["windows"] += 1
        entry["duration_s"] += times[-1] - times[0]
        entry["intervals_ms"].extend(intervals)
        entry["late_frames"] += sum(i > late_limit_ms for i in intervals)
    return raw


def summarize_idle(raw: dict[str, dict[str, Any]]) -> dict[str, dict[str, Any]]:
    summary = {}
    for label, entry in raw.items():
        intervals = entry["intervals_ms"]
        duration = entry["duration_s"]
        summary[label] = {
            "windows": entry["windows"],
            "duration_s": round(duration, 3),
            "frames": len(intervals) + entry["windows"],
            "late_frames": entry["late_frames"],
            "late_frames_per_s": round(entry["late_frames"] / duration, 4) if duration > 0 else None,
            "interval_p50_ms": round_or_none(percentile(intervals, 0.5)),
            "interval_p95_ms": round_or_none(percentile(intervals, 0.95)),
            "interval_max_ms": round_or_none(maximum(intervals)),
        }
    return summary


def pool_idle(parts: list[dict[str, dict[str, Any]]]) -> dict[str, dict[str, Any]]:
    pooled: dict[str, dict[str, Any]] = {}
    for part in parts:
        for label, entry in part.items():
            target = pooled.setdefault(
                label, {"windows": 0, "duration_s": 0.0, "intervals_ms": [], "late_frames": 0}
            )
            target["windows"] += entry["windows"]
            target["duration_s"] += entry["duration_s"]
            target["intervals_ms"].extend(entry["intervals_ms"])
            target["late_frames"] += entry["late_frames"]
    return pooled


def group_actions(actions: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    groups: dict[str, dict[str, Any]] = {}
    for action in actions:
        group = groups.setdefault(
            action["group"],
            {"name": action["name"], "variant": action["variant"], "n": 0, "metrics": {}},
        )
        group["n"] += 1
    for key, group in groups.items():
        members = [a for a in actions if a["group"] == key]
        for metric, _, transform in GROUP_METRICS:
            values = [transform(a[metric]) for a in members if a.get(metric) is not None]
            group["metrics"][metric] = {
                "median": round_or_none(statistics.median(values)) if values else None,
                "max": round_or_none(max(values)) if values else None,
            }
    return groups


def analyze(recordings: list[Recording]) -> tuple[dict[str, Any], dict[str, Any]]:
    """Analyze every recording; returns the pooled analysis."""
    all_actions: list[dict[str, Any]] = []
    headers: list[dict[str, Any]] = []
    idle_parts: list[dict[str, dict[str, Any]]] = []
    for number, rec in enumerate(recordings):
        results = [analyze_action(rec, i) for i in range(len(rec.actions))]
        for result in results:
            result["recording"] = number
        all_actions.extend(results)
        idle_parts.append(collect_idle(rec, results))
        headers.append(
            {
                "path": rec.path,
                "configuration": rec.configuration,
                "refresh_interval_ms": round(rec.refresh_s * 1000.0, 3),
                "scenario": rec.scenario,
                "spring": rec.spring,
                "frame_count": len(rec.frames),
                "duration_s": round(rec.times[-1] - rec.times[0], 3) if rec.times else 0.0,
                "action_count": len(rec.actions),
                "toolbar_signatures": rec.signatures,
            }
        )
    return {
        "schema": ANALYSIS_SCHEMA,
        "recordings": headers,
        "actions": all_actions,
        "groups": group_actions(all_actions),
        "idle": summarize_idle(pool_idle(idle_parts)),
    }


# --------------------------------------------------------------------------
# Text and markdown rendering
# --------------------------------------------------------------------------


def fmt(value: Any, digits: int = 2) -> str:
    if value is None:
        return "-"
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, int):
        return str(value)
    text = f"{value:.{digits}f}"
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def fmt_delta(value: float | None) -> str:
    if value is None:
        return "-"
    text = fmt(value)
    return f"+{text}" if value > 0 else text


def format_table(
    headers: list[str], rows: list[list[str]], markdown: bool, left_columns: int = 1
) -> str:
    if markdown:
        lines = [
            "| " + " | ".join(headers) + " |",
            "| "
            + " | ".join(["---"] * left_columns + ["---:"] * (len(headers) - left_columns))
            + " |",
        ]
        lines += ["| " + " | ".join(row) + " |" for row in rows]
        return "\n".join(lines)
    widths = [max(len(r[c]) for r in [headers, *rows]) for c in range(len(headers))]
    def line(row: list[str]) -> str:
        cells = [cell.ljust(w) for cell, w in zip(row[:left_columns], widths)] + [
            cell.rjust(w) for cell, w in zip(row[left_columns:], widths[left_columns:])
        ]
        return "  ".join(cells).rstrip()
    return "\n".join([line(headers), line(["-" * w for w in widths]), *map(line, rows)])


def heading(text: str, markdown: bool, level: int = 2) -> str:
    return f"{'#' * level} {text}" if markdown else f"{text}\n{'=' * len(text)}"


def action_label(action: dict[str, Any], multiple: bool) -> str:
    prefix = f"r{action['recording'] + 1}#" if multiple else "#"
    return f"{action['group']} {prefix}{action['id']} (cycle {action['cycle']})"


def describe_scenario(header: dict[str, Any]) -> str:
    scenario = header["scenario"]
    return ", ".join(f"{k}={v}" for k, v in scenario.items()) or "-"


def build_report(analysis: dict[str, Any], markdown: bool) -> str:
    out: list[str] = []
    recordings = analysis["recordings"]
    multiple = len(recordings) > 1
    out.append(heading("Motion benchmark", markdown, 1))
    for number, header in enumerate(recordings, 1):
        name = f"Recording {number}: " if multiple else ""
        bullet, sub = ("- ", "  - ") if markdown else ("  ", "    ")
        out.append(
            f"{bullet}{name}{header['configuration']} build, refresh {fmt(header['refresh_interval_ms'])} ms, "
            f"{header['frame_count']} frames over {fmt(header['duration_s'], 1)} s, "
            f"{header['action_count']} actions"
        )
        out.append(f"{sub}scenario: {describe_scenario(header)}; spring: {header['spring'] or '-'}")
        if multiple:
            out.append(f"{sub}{header['path']}")
    out.append("")

    groups = analysis["groups"]
    out.append(heading("Grouped metrics (median / max)", markdown))
    if markdown:
        headers = ["Metric"] + [f"{key} (n={g['n']})" for key, g in groups.items()]
        rows = [
            [label] + [
                f"{fmt(g['metrics'][metric]['median'])} / {fmt(g['metrics'][metric]['max'])}"
                for g in groups.values()
            ]
            for metric, label, _ in GROUP_METRICS
        ]
        out.append(format_table(headers, rows, True))
    else:
        for key, group in groups.items():
            out.append(f"\n{key}  (n={group['n']})")
            rows = [
                [label, fmt(group["metrics"][metric]["median"]), fmt(group["metrics"][metric]["max"])]
                for metric, label, _ in GROUP_METRICS
            ]
            out.append(format_table(["metric", "median", "max"], rows, False))
    out.append("")

    out.append(heading("Hitches and toolbar changes", markdown))
    details = []
    for action in analysis["actions"]:
        parts = []
        if action["hitches"]:
            parts.append(
                "hitches "
                + ", ".join(f"+{fmt(h['offset_ms'], 0)}ms:{fmt(h['interval_ms'], 1)}ms" for h in action["hitches"])
            )
        if action["toolbar_changes"]:
            parts.append(
                "toolbar "
                + ", ".join(
                    f"+{fmt(c['offset_ms'], 0)}ms {c['from']}->{c['to']}"
                    f"{' (in motion)' if c['during_motion'] else ''}"
                    for c in action["toolbar_changes"]
                )
            )
        if parts:
            details.append(f"{action_label(action, multiple)}: " + "; ".join(parts))
    out.extend((f"- {d}" if markdown else f"  {d}") for d in details) if details else out.append("none")
    out.append("")

    out.append(heading("Idle", markdown))
    if not analysis["idle"]:
        out.append("no idle stretches in the recordings")
    else:
        headers = ["window", "windows", "seconds", "late frames", "late/s", "p50 ms", "p95 ms", "max ms"]
        rows = [
            [
                label, str(s["windows"]), fmt(s["duration_s"], 1), str(s["late_frames"]),
                fmt(s["late_frames_per_s"], 3), fmt(s["interval_p50_ms"]),
                fmt(s["interval_p95_ms"]), fmt(s["interval_max_ms"]),
            ]
            for label, s in analysis["idle"].items()
        ]
        out.append(format_table(headers, rows, markdown))
    return "\n".join(out)


def build_compare(current: dict[str, Any], baseline: dict[str, Any], markdown: bool) -> str:
    headers = ["group", "metric", "base med", "base max", "new med", "new max", "d med", "d max"]
    rows = []
    keys = list(dict.fromkeys([*baseline["groups"], *current["groups"]]))
    for key in keys:
        old = baseline["groups"].get(key)
        new = current["groups"].get(key)
        for metric, label, _ in GROUP_METRICS:
            o = (old or {"metrics": {}})["metrics"].get(metric, {})
            n = (new or {"metrics": {}})["metrics"].get(metric, {})
            values = [o.get("median"), o.get("max"), n.get("median"), n.get("max")]
            if all(v in (None, 0) for v in values):
                continue
            def delta(field: str) -> float | None:
                a, b = o.get(field), n.get(field)
                return None if a is None or b is None else b - a
            rows.append(
                [key, label, fmt(o.get("median")), fmt(o.get("max")), fmt(n.get("median")),
                 fmt(n.get("max")), fmt_delta(delta("median")), fmt_delta(delta("max"))]
            )
    counts = ", ".join(
        f"{key}: n {(baseline['groups'].get(key) or {}).get('n', 0)} -> {(current['groups'].get(key) or {}).get('n', 0)}"
        for key in keys
    )
    title = heading("Comparison with baseline", markdown)
    body = format_table(headers, rows, markdown, left_columns=2) if rows else "no non-zero metrics"
    return f"{title}\n{counts}\n\n{body}"


# --------------------------------------------------------------------------
# HTML report
# --------------------------------------------------------------------------

HTML_STYLE = """
body{font:13px/1.4 -apple-system,system-ui,sans-serif;background:#f6f6f4;color:#222;margin:24px}
h1{font-size:20px;margin:0 0 4px}h2{font-size:15px;margin:28px 0 8px}
.meta{color:#666;margin-bottom:8px}
.grid{display:flex;flex-wrap:wrap;gap:12px}
.card{background:#fff;border:1px solid #ddd;border-radius:6px;padding:6px}
svg text{font:11px -apple-system,system-ui,sans-serif;fill:#444}
.legend{color:#666;margin:6px 0}
"""

OBSERVED_COLOR = "#3b6ea5"
LATE_COLOR = "#c8372d"
GRID_COLOR = "#e4e4e0"


def svg_axes(width: int, height: int, margin: tuple[int, int, int, int], x_ticks: list[tuple[float, str]],
             y_ticks: list[tuple[float, str]], x_label: str, y_label: str,
             sx: Callable[[float], float], sy: Callable[[float], float]) -> str:
    left, top, right, bottom = margin
    parts = [
        f'<rect x="{left}" y="{top}" width="{width - left - right}" height="{height - top - bottom}" '
        f'fill="none" stroke="#bbb"/>'
    ]
    for value, text in x_ticks:
        x = sx(value)
        parts.append(f'<line x1="{x:.1f}" y1="{top}" x2="{x:.1f}" y2="{height - bottom}" stroke="{GRID_COLOR}"/>')
        parts.append(f'<text x="{x:.1f}" y="{height - bottom + 14}" text-anchor="middle">{html.escape(text)}</text>')
    for value, text in y_ticks:
        y = sy(value)
        parts.append(f'<line x1="{left}" y1="{y:.1f}" x2="{width - right}" y2="{y:.1f}" stroke="{GRID_COLOR}"/>')
        parts.append(f'<text x="{left - 6}" y="{y + 4:.1f}" text-anchor="end">{html.escape(text)}</text>')
    parts.append(
        f'<text x="{(left + width - right) / 2:.0f}" y="{height - 6}" text-anchor="middle">{html.escape(x_label)}</text>'
    )
    parts.append(
        f'<text transform="translate(12 {(top + height - bottom) / 2:.0f}) rotate(-90)" '
        f'text-anchor="middle">{html.escape(y_label)}</text>'
    )
    return "".join(parts)


def progress_chart(key: str, actions: list[dict[str, Any]], duration_s: float) -> str:
    width, height, margin = 380, 250, (46, 26, 12, 38)
    left, top, right, bottom = margin
    curves = [a["curve"] for a in actions if a.get("curve")]
    x_max = max([c[-1][0] for c in curves] + [400.0])
    x_max = math.ceil(x_max / 100.0) * 100.0
    values = [p for c in curves for _, p, _ in c]
    y_min = max(-0.5, min([0.0] + values))
    y_max = min(1.5, max([1.1] + values))

    def sx(ms: float) -> float:
        return left + (ms / x_max) * (width - left - right)

    def sy(p: float) -> float:
        return top + (1 - (p - y_min) / (y_max - y_min)) * (height - top - bottom)

    x_step = 50 if x_max <= 400 else 100
    x_ticks = [(float(v), str(v)) for v in range(0, int(x_max) + 1, x_step)]
    y_ticks = [(v, fmt(v)) for v in (0.0, 0.5, 1.0) if y_min <= v <= y_max]
    parts = [svg_axes(width, height, margin, x_ticks, y_ticks, "ms since action", "progress", sx, sy)]
    omega = 2.0 * math.pi / duration_s
    ideal = " ".join(
        f"{sx(ms):.1f},{sy(spring_progress(ms / 1000.0, omega)):.1f}" for ms in range(0, int(x_max) + 1, 4)
    )
    for curve in curves:
        points = " ".join(f"{sx(ms):.1f},{sy(max(y_min, min(y_max, p))):.1f}" for ms, p, _ in curve)
        parts.append(f'<polyline points="{points}" fill="none" stroke="{OBSERVED_COLOR}" stroke-opacity="0.45" stroke-width="1"/>')
    parts.append(f'<polyline points="{ideal}" fill="none" stroke="#222" stroke-width="1.2" stroke-dasharray="5 3"/>')
    for curve in curves:
        for ms, p, late in curve:
            if late:
                parts.append(
                    f'<circle cx="{sx(ms):.1f}" cy="{sy(max(y_min, min(y_max, p))):.1f}" r="3.2" '
                    f'fill="{LATE_COLOR}" fill-opacity="0.35" stroke="{LATE_COLOR}"/>'
                )
    parts.append(
        f'<text x="{left}" y="16" font-weight="600">{html.escape(key)}  (n={len(actions)})</text>'
    )
    return f'<svg width="{width}" height="{height}" viewBox="0 0 {width} {height}">{"".join(parts)}</svg>'


def interval_strip(rec: Recording, number: int) -> str:
    width, height, margin = 960, 190, (46, 14, 12, 38)
    left, top, right, bottom = margin
    times = rec.times
    if len(times) < 2:
        return ""
    origin, span = times[0], max(times[-1] - times[0], 1e-6)
    refresh_ms = rec.refresh_s * 1000.0
    intervals = [(b, (b - a) * 1000.0) for a, b in zip(times, times[1:])]
    y_max = min(200.0, max(50.0, math.ceil(max(i for _, i in intervals) / 10.0) * 10.0))

    def sx(t: float) -> float:
        return left + ((t - origin) / span) * (width - left - right)

    def sy(ms: float) -> float:
        return top + (1 - min(ms, y_max) / y_max) * (height - top - bottom)

    seconds_step = max(1, int(span / 12))
    x_ticks = [(origin + s, str(s)) for s in range(0, int(span) + 1, seconds_step)]
    y_ticks = [(v, fmt(v)) for v in sorted({0.0, refresh_ms, y_max})]
    parts = [svg_axes(width, height, margin, x_ticks, y_ticks, "seconds since first frame", "frame interval ms", sx, sy)]
    for action in rec.actions:
        parts.append(
            f'<line x1="{sx(action.time):.1f}" y1="{top}" x2="{sx(action.time):.1f}" y2="{height - bottom}" '
            f'stroke="{OBSERVED_COLOR}" stroke-opacity="0.35"><title>{html.escape(action.group)} #{action.id}</title></line>'
        )
    limit = rec.late_limit_s * 1000.0
    parts.append(
        f'<line x1="{left}" y1="{sy(limit):.1f}" x2="{width - right}" y2="{sy(limit):.1f}" '
        f'stroke="{LATE_COLOR}" stroke-dasharray="4 3" stroke-opacity="0.6"/>'
    )
    base = sy(0.0)
    normal = "".join(f"M{sx(t):.1f},{base:.1f}V{sy(i):.1f}" for t, i in intervals if i <= limit)
    late = "".join(f"M{sx(t):.1f},{base:.1f}V{sy(i):.1f}" for t, i in intervals if i > limit)
    parts.append(f'<path d="{normal}" stroke="#8a8a85" stroke-width="1" fill="none"/>')
    parts.append(f'<path d="{late}" stroke="{LATE_COLOR}" stroke-width="1.6" fill="none"/>')
    return f'<svg width="{width}" height="{height}" viewBox="0 0 {width} {height}">{"".join(parts)}</svg>'


def render_html(analysis: dict[str, Any], recordings: list[Recording]) -> str:
    sections = [
        "<h1>Motion benchmark</h1>",
        '<div class="meta">'
        + "<br>".join(
            html.escape(
                f"{h['path']}: {h['configuration']}, refresh {fmt(h['refresh_interval_ms'])} ms, "
                f"{h['frame_count']} frames, scenario {describe_scenario(h)}"
            )
            for h in analysis["recordings"]
        )
        + "</div>",
        '<div class="legend">Solid blue: observed progress per action. Dashed black: ideal critically damped '
        "spring from the action time. Red circles: late frames (interval over 1.5x refresh).</div>",
        '<div class="grid">',
    ]
    for key, group in analysis["groups"].items():
        members = [a for a in analysis["actions"] if a["group"] == key]
        duration = recordings[members[0]["recording"]].spring_duration_s
        sections.append(f'<div class="card">{progress_chart(key, members, duration)}</div>')
    sections.append("</div>")
    sections.append("<h2>Frame intervals</h2>")
    sections.append(
        '<div class="legend">Each stem is one frame interval. Red stems exceed 1.5x refresh '
        "(dashed line). Blue vertical lines mark actions.</div>"
    )
    for number, rec in enumerate(recordings, 1):
        sections.append(f"<div class=\"meta\">Recording {number}: {html.escape(rec.path)}</div>")
        sections.append(f'<div class="card">{interval_strip(rec, number)}</div>')
    return (
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>Motion benchmark</title>"
        f"<style>{HTML_STYLE}</style></head><body>{''.join(sections)}</body></html>"
    )


# --------------------------------------------------------------------------
# Assertions
# --------------------------------------------------------------------------


def find_violations(
    analysis: dict[str, Any], recordings: list[Recording], args: argparse.Namespace
) -> list[str]:
    violations: list[str] = []
    multiple = len(recordings) > 1
    max_interval = args.max_interval_ms
    for action in analysis["actions"]:
        rec = recordings[action["recording"]]
        label = action_label(action, multiple)
        interval_limit = max_interval if max_interval is not None else LATE_FACTOR * rec.refresh_s * 1000.0

        def check(condition: bool, message: str) -> None:
            if condition:
                violations.append(f"{label}: {message}")

        def above(key: str, limit: float, unit: str) -> None:
            value = action.get(key)
            check(value is not None and value > limit, f"{key} {fmt(value)}{unit} > {fmt(limit)}{unit}")

        above("late_frames", args.max_late_frames, "")
        above("interval_max_ms", interval_limit, " ms")
        above("max_position_error_pt", args.max_position_error_pt, " pt")
        above("start_snap_pt", args.max_snap_pt, " pt")
        above("end_snap_pt", args.max_snap_pt, " pt")
        above("reference_mismatch_pt", args.max_reference_mismatch_pt, " pt")
        above("max_gap_deviation_pt", args.max_gap_deviation_pt, " pt")
        above("max_title_drift_pt", args.max_title_drift_pt, " pt")
        above("content_jumps", 0, "")
        check(
            bool(action["reference_presence_mismatches"]),
            "reference probe presence differs: " + ", ".join(action["reference_presence_mismatches"]),
        )
        if not args.allow_toolbar_changes:
            check(action["toolbar_changes_in_motion"] > 0, f"{action['toolbar_changes_in_motion']} toolbar change(s) during motion")
        reduce_motion = bool(rec.scenario.get("reduceMotion"))
        expects_motion = action["moving_probe"] is not None and not reduce_motion
        check(expects_motion and not action["moved"], "no motion detected")
        check(action["moved"] and not action["settled"], "did not settle before the next action")
    return violations


# --------------------------------------------------------------------------
# Self test
# --------------------------------------------------------------------------


def synthesize_recording() -> dict[str, Any]:
    """60 Hz recording: clean open, clean close, stalled+glitched open, close with toolbar change."""
    refresh = 1.0 / 60.0
    omega = 2.0 * math.pi / 0.24
    window, pane_width = 1000.0, 400.0
    plans = [
        {"name": "pane-open", "time": 1.004, "variant": "cold"},
        {"name": "pane-close", "time": 4.004, "variant": "cold"},
        {"name": "pane-open", "time": 7.004, "variant": "warm", "stall": 0.3, "glitch": True},
        {"name": "pane-close", "time": 10.004, "variant": "warm", "toolbar": True},
        {"name": "full-width-close", "time": 13.004, "variant": "warm", "static": True},
    ]
    grid = [k * refresh for k in range(int(16.0 / refresh) + 1)]
    for plan in plans:
        plan["first_frame"] = plan["time"]
        plan["start"] = plan["time"]
        if plan.get("stall"):
            plan["first_frame"] = next(t for t in grid if t >= plan["time"] + plan["stall"])
            plan["start"] = plan["first_frame"] - 0.008
    times = [
        t for t in grid
        if not any(plan["time"] < t < plan["first_frame"] for plan in plans)
    ]

    frames = []
    for t in times:
        plan = next((p for p in reversed(plans) if p["time"] <= t and not p.get("static")), None)
        pane_x: float | None = None
        rows, index = 0, -1
        if plan is not None:
            p = spring_progress(t - plan["start"], omega)
            index = round((t - plan["start"]) / refresh)
            if plan["name"] == "pane-open":
                pane_x = window - pane_width * p
                rows = 151 if t - plan["start"] >= 0.12 else 0
            elif p < 0.995:
                pane_x = window - pane_width * (1 - p)
                rows = 151
        probes: dict[str, list[float]] = {}
        timelines = []
        if pane_x is None:
            probes["primary"] = [0, 0, window, 800]
        else:
            glitch = plan.get("glitch") and index == 5
            probes["primary"] = [0, 0, pane_x, 800]
            probes["pane"] = [pane_x + (80 if glitch else 0), 0, pane_width, 800]
            probes["toolbarTitle"] = [pane_x + 12, 780, 100, 20]
            distance = 10.0 if plan.get("glitch") and index == 10 else 0.0
            timelines.append(
                {"frame": [pane_x, 0, pane_width, 700], "documentHeight": 5000.0,
                 "offsetY": 4100.0, "distanceFromBottom": distance, "rows": rows}
            )
        toolbar = 1 if plan and plan.get("toolbar") and t - plan["start"] >= 0.1 else 0
        frames.append(
            {"time": t, "target": t + refresh, "callback": t + 0.0005, "probes": probes,
             "timelines": timelines, "toolbar": toolbar}
        )

    return {
        "schema": RECORDING_SCHEMA,
        "configuration": "release",
        "refreshIntervalMS": refresh * 1000.0,
        "scenario": {"cycles": 1, "reduceMotion": False},
        "spring": {"durationS": 0.24, "bounce": 0.0},
        "actions": [
            {"id": i, "name": p["name"], "cycle": i // 2, "time": p["time"], "variant": p["variant"],
             "movingProbe": None if p.get("static") else "pane", "edge": None if p.get("static") else "minX"}
            for i, p in enumerate(plans)
        ],
        "frames": frames,
        "toolbarSignatures": ["sig0", "sig1"],
        "mainThreadBusy": [{"start": 7.004, "durationMS": 300.0}],
        "idle": [{"start": 2.5, "end": 3.8, "label": "panels-hidden"}],
        "references": {
            "pane-open": {"probes": {
                "pane": [600, 0, 400, 800], "primary": [0, 0, 600, 800], "toolbarTitle": [612, 780, 100, 20]}},
            "pane-close": {"probes": {"primary": [0, 0, 1000, 800]}},
        },
    }


def default_limits() -> argparse.Namespace:
    return build_parser().parse_args(["--assert"])


def run_self_test() -> int:
    data = json.loads(json.dumps(synthesize_recording()))
    recordings = [parse_recording(data, "synthetic-1"), parse_recording(data, "synthetic-2")]
    analysis = analyze(recordings)
    by_id = {(a["recording"], a["id"]): a for a in analysis["actions"]}
    clean_open, clean_close = by_id[0, 0], by_id[0, 1]
    stalled, toolbar, static = by_id[0, 2], by_id[0, 3], by_id[0, 4]
    args = default_limits()
    violations = find_violations(analysis, recordings, args)

    def mentions(label_fragment: str) -> list[str]:
        return [v for v in violations if label_fragment in v]

    for clean in (clean_open, clean_close):
        assert clean["moved"] and clean["settled"], clean
        assert clean["late_frames"] == 0 and clean["jump_frames"] == 0, clean
        assert clean["backward_steps"] == 0 and clean["content_jumps"] == 0, clean
        assert clean["max_position_error_pt"] < 1.0, clean["max_position_error_pt"]
        assert clean["start_snap_pt"] < 1.0, clean["start_snap_pt"]
        assert clean["start_delay_ms"] < 5.0, clean["start_delay_ms"]
        assert clean["max_gap_deviation_pt"] == 0 and clean["max_title_drift_pt"] == 0, clean
        assert clean["toolbar_changes_in_motion"] == 0, clean
        assert 250 < clean["settle_ms"] < 450, clean["settle_ms"]
    assert clean_open["reference_mismatch_pt"] < 1.0 and clean_open["end_snap_pt"] < 1.0
    assert clean_close["removed"] and clean_close["end_snap_pt"] is None
    assert clean_open["appearing"] and clean_open["travel_pt"] > 395, clean_open["travel_pt"]
    for action in (clean_open, clean_close):
        assert not mentions(f"#{action['id']} "[:0] + f"r1#{action['id']} "), violations

    assert stalled["late_frames"] >= 1 and stalled["interval_max_ms"] >= 300, stalled
    assert stalled["first_motion_latency_ms"] >= 290 and stalled["start_delay_ms"] >= 250, stalled
    assert stalled["jump_frames"] >= 1 and stalled["backward_steps"] >= 1, stalled
    assert stalled["max_position_error_pt"] > 8, stalled["max_position_error_pt"]
    assert stalled["max_gap_deviation_pt"] > 25 and stalled["max_title_drift_pt"] > 25, stalled
    assert stalled["content_jumps"] >= 1, stalled
    assert 299 < stalled["main_thread_busy_max_ms"] < 301, stalled
    assert mentions("r1#2 "), violations

    assert toolbar["toolbar_changes_in_motion"] == 1, toolbar["toolbar_changes"]
    assert toolbar["toolbar_changes"][0]["from"] == 0 and toolbar["toolbar_changes"][0]["to"] == 1
    toolbar_violations = mentions("r1#3 ")
    assert toolbar_violations and all("toolbar" in v for v in toolbar_violations), violations

    assert not static["moved"] and static["max_position_error_pt"] is None, static
    assert static["late_frames"] == 0 and static["pacing_end_time"] >= static["time"] + 0.6
    assert not mentions("r1#4 "), violations
    assert not mentions("r1#0 ") and not mentions("r1#1 "), violations
    args.allow_toolbar_changes = True
    assert not any("toolbar" in v for v in find_violations(analysis, recordings, args))

    assert analysis["groups"]["pane-open [cold]"]["n"] == 2
    assert analysis["groups"]["pane-open [warm]"]["metrics"]["late_frames"]["max"] >= 1
    assert analysis["groups"]["pane-open [cold]"]["metrics"]["late_frames"]["max"] == 0
    assert set(analysis["idle"]) == {AUTO_IDLE_LABEL, "panels-hidden"}, analysis["idle"]
    assert all(s["late_frames"] == 0 for s in analysis["idle"].values()), analysis["idle"]
    assert analysis["idle"]["panels-hidden"]["windows"] == 2

    json.dumps(analysis)
    assert "<svg" in render_html(analysis, recordings)
    for markdown in (False, True):
        assert "pane-open [cold]" in build_report(analysis, markdown)
        assert "+0" not in build_compare(analysis, analysis, markdown).split("\n\n", 1)[1]
    print("self-test passed")
    return 0


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("recordings", nargs="*", help="recording JSON files (repeated runs of one scenario)")
    parser.add_argument("--json", metavar="OUT", help="write the full analysis as JSON")
    parser.add_argument("--html", metavar="OUT", help="write a self-contained HTML report")
    parser.add_argument("--compare", metavar="BASELINE.json", help="previous --json output to compare against")
    parser.add_argument("--markdown", action="store_true", help="print tables as GitHub markdown")
    parser.add_argument("--self-test", action="store_true", help="run the synthetic self-test and exit")
    parser.add_argument("--assert", dest="strict", action="store_true", help="exit 1 on threshold violations")
    parser.add_argument("--max-late-frames", type=int, default=0)
    parser.add_argument("--max-interval-ms", type=float, default=None, help="default: 1.5x refresh")
    parser.add_argument("--max-position-error-pt", type=float, default=8.0)
    parser.add_argument("--max-snap-pt", type=float, default=2.0)
    parser.add_argument("--max-reference-mismatch-pt", type=float, default=1.0)
    parser.add_argument("--max-gap-deviation-pt", type=float, default=1.0)
    parser.add_argument("--max-title-drift-pt", type=float, default=2.0)
    parser.add_argument("--allow-toolbar-changes", action="store_true")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.self_test:
        return run_self_test()
    if not args.recordings:
        parser.error("at least one recording is required")

    recordings = []
    for path in args.recordings:
        recording = parse_recording(json.loads(Path(path).read_text()), path)
        if not recording.frames or not recording.actions:
            print(f"error: {path}: recording has no frames or no actions", file=sys.stderr)
            return 2
        recordings.append(recording)
    configurations = {r.configuration for r in recordings}
    if len(configurations) > 1:
        print(f"warning: mixed configurations {sorted(configurations)}", file=sys.stderr)

    analysis = analyze(recordings)
    print(build_report(analysis, args.markdown))
    if args.compare:
        baseline = json.loads(Path(args.compare).read_text())
        print()
        print(build_compare(analysis, baseline, args.markdown))
    if args.json:
        Path(args.json).write_text(json.dumps(analysis, indent=2) + "\n")
    if args.html:
        Path(args.html).write_text(render_html(analysis, recordings))

    if args.strict:
        violations = find_violations(analysis, recordings, args)
        for violation in violations:
            print(f"VIOLATION {violation}")
        if violations:
            return 1
        print("assert: no violations")
    return 0


if __name__ == "__main__":
    sys.exit(main())
