#!/usr/bin/env python3
"""Attribute side chat motion CPU samples and hitches to benchmark actions.

Reads xctrace exports from a motion_benchmark.sh --trace run. The
SideChatMotionAction signpost intervals (message "<name> <variant> <cycle>")
define one window per action. Windows are grouped by "<name> <variant>" and,
per group, this prints the main thread time-profile hot frames (inclusive and
leaf) and the hitches that overlap the windows, plus the hitch rate outside
every window. Every table is optional; missing or empty exports are reported
and skipped. Shared XML helpers come from time_profile_hotspots.py.

Usage: motion_benchmark_profile.py --signposts signposts.xml
           [--time-profile time-profile.xml] [--hitches hitches.xml]
           [--process SakuraCord] [--limit 12]
       motion_benchmark_profile.py --self-test
"""

from __future__ import annotations

import argparse
import collections
import io
import os
import re
import sys
import xml.etree.ElementTree as ET
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from time_profile_hotspots import direct_child, resolved  # noqa: E402

SIGNPOST_NAME = "SideChatMotionAction"
MESSAGE_TAGS = (
    "message", "formatted-message", "os-log-message", "signpost-message",
    "event-message",
)
MESSAGE_PATTERN = re.compile(r"^[A-Za-z][\w.-]* \S+ \d+$")
# Frames from these binaries or names only add noise to an inclusive table.
NOISE_BINARY_PREFIXES = ("libsystem_", "libdyld", "dyld", "libdispatch")
NOISE_NAMES = {"start", "main"}

Window = tuple[float, float]


class Registry:
    """Resolves xctrace id/ref values; later rows reference earlier ids."""

    def __init__(self) -> None:
        self.display: dict[tuple[str, str], str] = {}
        self.raw: dict[tuple[str, str], str] = {}

    def register(self, row: ET.Element) -> None:
        for element in row.iter():
            identifier = element.get("id")
            if identifier is not None:
                key = (element.tag, identifier)
                self.display[key] = element.get("fmt", element.text or "")
                self.raw[key] = element.text or element.get("fmt", "")

    def value(self, element: ET.Element | None, *, raw: bool = False) -> str | None:
        if element is None:
            return None
        reference = element.get("ref")
        if reference is not None:
            return (self.raw if raw else self.display).get((element.tag, reference))
        if raw:
            return (element.text or element.get("fmt", "")).strip()
        return element.get("fmt", (element.text or "").strip())


def process_matches(query: str, text: str | None) -> bool:
    """Unresolvable or absent process values are accepted: traces are attached."""
    if not query or not text:
        return True
    return re.search(re.escape(query), text, re.IGNORECASE) is not None


def row_message(row: ET.Element, registry: Registry) -> str:
    for tag in MESSAGE_TAGS:
        text = registry.value(direct_child(row, tag))
        if text:
            return text.strip()
    known = {"signpost-name", "event-type", "event-time", "subsystem", "category"}
    for element in row.iter():
        if element is row or element.tag in known:
            continue
        text = (registry.value(element) or "").strip()
        if MESSAGE_PATTERN.match(text):
            return text
    return ""


def load_actions(path: str, process: str) -> dict[str, list[Window]]:
    """Return {"<name> <variant>": [(begin_s, end_s), ...]} in time order."""
    registry = Registry()
    starts: dict[tuple[str, str], list[tuple[float, str]]] = collections.defaultdict(list)
    seen: set[tuple[str, str, str, str]] = set()
    groups: dict[str, list[Window]] = collections.defaultdict(list)
    for _, row in ET.iterparse(path, events=("end",)):
        if row.tag != "row":
            continue
        registry.register(row)
        name = registry.value(direct_child(row, "signpost-name"))
        event_type = registry.value(direct_child(row, "event-type"))
        raw_time = registry.value(direct_child(row, "event-time"), raw=True)
        owner = registry.value(direct_child(row, "process"))
        if (
            name != SIGNPOST_NAME
            or event_type not in {"Begin", "End"}
            or raw_time is None
            or not raw_time.isdigit()
            or not process_matches(process, owner)
        ):
            row.clear()
            continue
        identifier = registry.value(direct_child(row, "os-signpost-identifier"), raw=True) or "missing"
        identity = (raw_time, event_type, owner or "", identifier)
        if identity in seen:
            row.clear()
            continue
        seen.add(identity)
        time = int(raw_time) / 1e9
        key = (owner or "", identifier)
        if event_type == "Begin":
            parts = row_message(row, registry).split()
            label = " ".join(parts[:2]) if parts else "unlabelled"
            starts[key].append((time, label))
        elif starts[key]:
            begin, label = starts[key].pop(0)
            if time >= begin:
                groups[label].append((begin, time))
        row.clear()
    for windows in groups.values():
        windows.sort()
    return dict(groups)


def in_any(time: float, windows: list[Window]) -> bool:
    return any(begin <= time < end for begin, end in windows)


def merge(windows: list[Window]) -> list[Window]:
    merged: list[Window] = []
    for begin, end in sorted(windows):
        if merged and begin <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((begin, end))
    return merged


def number(element: ET.Element | None, values: dict[str, float], scale: float) -> float | None:
    """Resolve a ref, or fall back to the element's own text when it has no id."""
    if element is None:
        return None
    if element.get("ref") is not None or element.get("id") is not None:
        return resolved(element, values)
    try:
        return float(element.text or "") / scale
    except ValueError:
        return None


def load_samples(path: str, process: str):
    """Return [(time_s, thread, weight_ms, stack)] for the process; stack is leaf first."""
    binaries: dict[str, str] = {}
    pids: dict[str, str] = {}
    times: dict[str, float] = {}
    weights: dict[str, float] = {}
    processes: dict[str, tuple[str, str]] = {}
    threads: dict[str, str] = {}
    frames: dict[str, tuple[str, str]] = {}
    stacks: dict[str, list[tuple[str, str]]] = {}
    samples = []
    pattern = re.compile(re.escape(process), re.IGNORECASE)
    for _, row in ET.iterparse(path, events=("end",)):
        if row.tag != "row":
            continue
        descendants = list(row.iter())
        for element in descendants:
            identifier = element.get("id")
            if identifier is None:
                continue
            if element.tag == "binary":
                binaries[identifier] = element.get("name", "")
            elif element.tag == "pid":
                pids[identifier] = element.text or ""
            elif element.tag == "sample-time":
                times[identifier] = float(element.text or 0) / 1e9
            elif element.tag == "weight":
                weights[identifier] = float(element.text or 0) / 1e6
        for element in descendants:
            identifier = element.get("id")
            if identifier is None or element.tag != "frame":
                continue
            binary = direct_child(element, "binary")
            if binary is None:
                binary_name = ""
            elif binary.get("ref") is not None:
                binary_name = binaries.get(binary.get("ref", ""), "")
            else:
                binary_name = binary.get("name", "")
            frames[identifier] = (element.get("name", ""), binary_name)
        for element in descendants:
            identifier = element.get("id")
            if identifier is None:
                continue
            if element.tag == "process":
                pid = resolved(direct_child(element, "pid"), pids)
                processes[identifier] = (element.get("fmt", ""), str(pid or ""))
            elif element.tag == "thread":
                threads[identifier] = element.get("fmt", "")
            elif element.tag == "tagged-backtrace":
                stack = []
                for frame in element.iter("frame"):
                    value = frames.get(frame.get("ref", frame.get("id", "")))
                    if value is not None:
                        stack.append(value)
                stacks[identifier] = stack
        owner = resolved(direct_child(row, "process"), processes)
        if owner is not None:
            name, pid = owner
            matches = pid == process if process.isdigit() else (
                pattern.search(name) or pattern.search(pid)
            )
            sample_time = number(direct_child(row, "sample-time"), times, 1e9)
            stack = resolved(direct_child(row, "tagged-backtrace"), stacks)
            if matches and sample_time is not None and stack:
                weight = number(direct_child(row, "weight"), weights, 1e6) or 1.0
                thread = resolved(direct_child(row, "thread"), threads) or ""
                samples.append((sample_time, thread, weight, stack))
        row.clear()
    return samples


def is_noise(frame: tuple[str, str]) -> bool:
    name, binary = frame
    return name in NOISE_NAMES or binary.startswith(NOISE_BINARY_PREFIXES)


def report_samples(groups: dict[str, list[Window]], samples, limit: int) -> None:
    if not samples:
        print("Time profile: no samples for the process.")
        return
    main = [s for s in samples if s[1].startswith("Main Thread")]
    if not main:
        first = samples[0][1]
        main = [s for s in samples if s[1] == first]
        print(f"Time profile: no 'Main Thread'; using first thread '{first}'.")
    for label, windows in groups.items():
        inclusive: dict[tuple[str, str], float] = collections.defaultdict(float)
        leaf: dict[tuple[str, str], float] = collections.defaultdict(float)
        total = 0.0
        count = 0
        for time, _, weight, stack in main:
            if not in_any(time, windows):
                continue
            count += 1
            total += weight
            leaf[stack[0]] += weight
            for frame in dict.fromkeys(stack):
                if not is_noise(frame):
                    inclusive[frame] += weight
        print(f"  Main thread samples: {count}, sampled {total:.1f} ms")
        if not count:
            continue
        for title, values in (("Inclusive", inclusive), ("Leaf", leaf)):
            print(f"  {title} (ms, % of sampled)")
            for (name, binary), ms in sorted(values.items(), key=lambda i: -i[1])[:limit]:
                print(f"    {ms:8.1f} ms {100 * ms / total:5.1f}%  {binary:22.22}  {name}")


def load_hitches(path: str, process: str) -> list[tuple[float, float]]:
    """Return [(start_s, duration_ms)] from a hitches export."""
    registry = Registry()
    hitches = []
    for _, row in ET.iterparse(path, events=("end",)):
        if row.tag != "row":
            continue
        registry.register(row)
        start = registry.value(direct_child(row, "start-time"), raw=True)
        duration = registry.value(direct_child(row, "duration"), raw=True)
        owner = registry.value(direct_child(row, "process"))
        if (
            start and duration and start.isdigit() and duration.isdigit()
            and process_matches(process, owner)
        ):
            hitches.append((int(start) / 1e9, int(duration) / 1e6))
        row.clear()
    return sorted(hitches)


def report_hitches(groups: dict[str, list[Window]], hitches, label: str) -> None:
    windows = groups[label]
    inside = [
        h for h in hitches
        if any(h[0] < end and h[0] + h[1] / 1e3 > begin for begin, end in windows)
    ]
    total = sum(d for _, d in inside)
    peak = max((d for _, d in inside), default=0.0)
    print(f"  Hitches: {len(inside)}, total {total:.1f} ms, max {peak:.1f} ms")


def report_idle_hitches(groups: dict[str, list[Window]], hitches) -> None:
    every = merge([w for windows in groups.values() for w in windows])
    span_begin, span_end = every[0][0], every[-1][1]
    busy = sum(end - begin for begin, end in every)
    idle_seconds = (span_end - span_begin) - busy
    idle = [
        h for h in hitches
        if span_begin <= h[0] < span_end and not in_any(h[0], every)
    ]
    total = sum(d for _, d in idle)
    rate = len(idle) / idle_seconds if idle_seconds > 0.05 else 0.0
    print(
        f"Idle hitches between actions ({idle_seconds:.1f} s idle of "
        f"{span_end - span_begin:.1f} s span): {len(idle)}, "
        f"{rate:.2f} late frames/s, total {total:.1f} ms"
    )


def usable(path: str | None) -> bool:
    return bool(path) and os.path.isfile(path) and os.path.getsize(path) > 0


def generate(args: argparse.Namespace) -> int:
    if not usable(args.signposts):
        print(f"No signposts export at {args.signposts}; nothing to attribute.")
        return 1
    try:
        groups = load_actions(args.signposts, args.process)
    except ET.ParseError as error:
        print(f"Signpost export is not valid XML ({error}).")
        return 1
    if not groups:
        print(f"No {SIGNPOST_NAME} intervals found for process {args.process}.")
        return 1
    samples = hitches = None
    if usable(args.time_profile):
        try:
            samples = load_samples(args.time_profile, args.process)
        except ET.ParseError as error:
            print(f"Time profile export is not valid XML ({error}); skipping.")
    elif args.time_profile:
        print("Time profile export missing or empty; skipping CPU attribution.")
    if usable(args.hitches):
        try:
            hitches = load_hitches(args.hitches, args.process)
        except ET.ParseError as error:
            print(f"Hitches export is not valid XML ({error}); skipping.")
            hitches = None
        if hitches is not None and not hitches:
            print("Hitches export has no rows; reporting zero hitches.")
    elif args.hitches:
        print("Hitches export missing or empty; skipping hitch counts.")
    print(f"process\t{args.process}")
    print(f"actions\t{sum(len(w) for w in groups.values())} in {len(groups)} groups")
    for label, windows in sorted(groups.items(), key=lambda i: i[1][0]):
        print()
        durations = ", ".join(f"{(e - b) * 1e3:.0f}" for b, e in windows[:3])
        print(f"== {label}  ({len(windows)} windows; first durations ms: {durations})")
        if samples is not None:
            report_samples({label: windows}, samples, args.limit)
        if hitches is not None:
            report_hitches(groups, hitches, label)
    if hitches is not None:
        print()
        report_idle_hitches(groups, hitches)
    return 0


# Synthetic exports in xctrace's id/ref style: first occurrence defines an id,
# later rows reference it.
SELF_TEST_SIGNPOSTS = """<trace-query-result><node><schema name="os-signpost"/>
<row><event-time id="1" fmt="00:01.000.000">1000000000</event-time>
<thread id="2" fmt="Main Thread"><tid id="3">1</tid><process id="4" fmt="SakuraCord (100)"><pid id="5">100</pid></process></thread>
<process ref="4"/><event-type id="6" fmt="Begin">Begin</event-type>
<os-signpost-identifier id="7">11</os-signpost-identifier><signpost-name id="8" fmt="SideChatMotionAction">SideChatMotionAction</signpost-name>
<message id="9" fmt="pane-open cold 0">pane-open cold 0</message></row>
<row><event-time fmt="00:02.200.000">2200000000</event-time><thread ref="2"/><process ref="4"/>
<event-type id="10" fmt="End">End</event-type><os-signpost-identifier ref="7"/><signpost-name ref="8"/><message id="12" fmt=""></message></row>
<row><event-time fmt="00:04.000.000">4000000000</event-time><thread ref="2"/><process ref="4"/><event-type ref="6"/>
<os-signpost-identifier id="13">12</os-signpost-identifier><signpost-name ref="8"/><message id="14" fmt="pane-close - 1">pane-close - 1</message></row>
<row><event-time fmt="00:05.200.000">5200000000</event-time><thread ref="2"/><process ref="4"/><event-type ref="10"/>
<os-signpost-identifier ref="13"/><signpost-name ref="8"/><message ref="12"/></row>
<row><event-time fmt="00:07.000.000">7000000000</event-time><thread ref="2"/><process ref="4"/><event-type ref="6"/>
<os-signpost-identifier id="15">13</os-signpost-identifier><signpost-name ref="8"/><message id="16" fmt="pane-open cold 2">pane-open cold 2</message></row>
<row><event-time fmt="00:08.200.000">8200000000</event-time><thread ref="2"/><process ref="4"/><event-type ref="10"/>
<os-signpost-identifier ref="15"/><signpost-name ref="8"/><message ref="12"/></row>
</node></trace-query-result>"""


def self_test_profile() -> str:
    rows = []
    # First row defines every id.
    rows.append(
        '<row><sample-time id="t0">1100000000</sample-time>'
        '<thread id="main" fmt="Main Thread 0x1 (SakuraCord, pid: 100)"/>'
        '<process id="p" fmt="SakuraCord (100)"><pid id="pid">100</pid></process>'
        '<weight id="w">1000000</weight>'
        '<tagged-backtrace id="s1"><backtrace>'
        '<frame id="f1" name="leafA"><binary id="b1" name="SakuraCord"/></frame>'
        '<frame id="f2" name="layoutPane"><binary ref="b1"/></frame>'
        '<frame id="f3" name="mach_msg"><binary id="b2" name="libsystem_kernel.dylib"/></frame>'
        '</backtrace></tagged-backtrace></row>'
    )
    stack1 = '<tagged-backtrace ref="s1"/>'
    # 49 more main-thread samples in the pane-open windows (1.1..2.2 and 7..8.2).
    for index in range(49):
        rows.append(
            f'<row><sample-time>{1_200_000_000 + index * 1_000_000}</sample-time>'
            '<thread ref="main"/><process ref="p"/><weight ref="w"/>' + stack1 + "</row>"
        )
    # Outside any window (3.0 s) and on another thread inside window 1.
    rows.append(
        '<row><sample-time>3000000000</sample-time><thread ref="main"/>'
        '<process ref="p"/><weight ref="w"/>' + stack1 + "</row>"
    )
    rows.append(
        '<row><sample-time>1500000000</sample-time><thread id="bg" fmt="Thread 2"/>'
        '<process ref="p"/><weight ref="w"/>' + stack1 + "</row>"
    )
    # pane-close window sample with a different leaf.
    rows.append(
        '<row><sample-time>4500000000</sample-time><thread ref="main"/>'
        '<process ref="p"/><weight ref="w"/>'
        '<tagged-backtrace id="s2"><backtrace><frame id="f4" name="leafB">'
        '<binary ref="b1"/></frame><frame ref="f2"/></backtrace></tagged-backtrace></row>'
    )
    return "<trace-query-result><node>" + "".join(rows) + "</node></trace-query-result>"


SELF_TEST_HITCHES = """<trace-query-result><node>
<row><start-time id="a" fmt="1">1500000000</start-time><duration id="d1" fmt="16 ms">16000000</duration><process id="p" fmt="SakuraCord (100)"/></row>
<row><start-time fmt="2">1800000000</start-time><duration id="d2" fmt="33 ms">33000000</duration><process ref="p"/></row>
<row><start-time fmt="3">4500000000</start-time><duration ref="d1"/><process ref="p"/></row>
<row><start-time fmt="4">3000000000</start-time><duration ref="d2"/><process ref="p"/></row>
<row><start-time fmt="5">6000000000</start-time><duration ref="d1"/><process ref="p"/></row>
</node></trace-query-result>"""


def self_test() -> int:
    import tempfile

    with tempfile.TemporaryDirectory() as directory:
        paths = {}
        for name, text in (
            ("signposts", SELF_TEST_SIGNPOSTS),
            ("profile", self_test_profile()),
            ("hitches", SELF_TEST_HITCHES),
        ):
            paths[name] = os.path.join(directory, f"{name}.xml")
            with open(paths[name], "w", encoding="utf-8") as handle:
                handle.write(text)

        groups = load_actions(paths["signposts"], "SakuraCord")
        assert set(groups) == {"pane-open cold", "pane-close -"}, groups
        assert groups["pane-open cold"] == [(1.0, 2.2), (7.0, 8.2)], groups
        assert groups["pane-close -"] == [(4.0, 5.2)], groups
        assert load_actions(paths["signposts"], "Other") == {}

        samples = load_samples(paths["profile"], "SakuraCord")
        assert len(samples) == 53, len(samples)
        assert samples[0][3][0] == ("leafA", "SakuraCord")

        hitches = load_hitches(paths["hitches"], "SakuraCord")
        assert [round(h[1]) for h in hitches] == [16, 33, 33, 16, 16], hitches

        args = argparse.Namespace(
            signposts=paths["signposts"], time_profile=paths["profile"],
            hitches=paths["hitches"], process="SakuraCord", limit=5,
        )
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            assert generate(args) == 0
        output = buffer.getvalue()
        print(output)
        assert "== pane-open cold  (2 windows" in output
        # 1 defining sample + 48 more inside 1.0..2.2 s (49 start at 1.2 s, last at 1.248).
        assert "Main thread samples: 50, sampled 50.0 ms" in output, output
        assert "Main thread samples: 1, sampled 1.0 ms" in output
        assert "layoutPane" in output and "mach_msg" not in output.split("Leaf")[0]
        assert "leafB" in output
        assert "Hitches: 2, total 49.0 ms, max 33.0 ms" in output
        assert "Hitches: 1, total 16.0 ms, max 16.0 ms" in output
        # Span 1.0..8.2 = 7.2 s, windows 3.6 s, idle 3.6 s; hitches at 3.0 and 6.0.
        assert "Idle hitches between actions (3.6 s idle of 7.2 s span): 2, 0.56" in output, output

        args.time_profile = os.path.join(directory, "missing.xml")
        args.hitches = None
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            assert generate(args) == 0
        assert "skipping CPU attribution" in buffer.getvalue()
    print("self-test passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--signposts", help="xctrace os-signpost export")
    parser.add_argument("--time-profile", help="xctrace time-profile export")
    parser.add_argument("--hitches", help="xctrace hitches export")
    parser.add_argument("--process", default="SakuraCord")
    parser.add_argument("--limit", type=int, default=12)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.signposts:
        parser.error("--signposts is required")
    return generate(args)


if __name__ == "__main__":
    sys.exit(main())
