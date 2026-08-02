#!/usr/bin/env python3
"""Summarize leaf and inclusive CPU samples from an xctrace time-profile export."""

from __future__ import annotations

import argparse
import collections
import re
import xml.etree.ElementTree as ET


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("xml")
    parser.add_argument("--process", default="SakuraCord", help="process name or PID")
    parser.add_argument("--start", type=float, default=0.0, help="inclusive trace time")
    parser.add_argument("--end", type=float, default=float("inf"), help="exclusive trace time")
    parser.add_argument("--limit", type=int, default=25)
    parser.add_argument("--app-only", action="store_true")
    parser.add_argument("--signposts", help="xctrace signpost XML export")
    parser.add_argument("--interval", help="use the outer bounds of this signpost interval")
    return parser.parse_args()


def direct_child(element: ET.Element, name: str) -> ET.Element | None:
    return next((child for child in element if child.tag == name), None)


def resolved(element: ET.Element | None, values: dict[str, object]):
    if element is None:
        return None
    reference = element.get("ref")
    return values.get(reference if reference is not None else element.get("id", ""))


def print_table(title: str, values: dict[tuple[str, str], float], limit: int) -> None:
    print(title)
    for (name, binary), weight in sorted(
        values.items(), key=lambda item: item[1], reverse=True
    )[:limit]:
        print(f"{weight:10.3f} ms  {binary:24}  {name}")


def signpost_interval_bounds(
    path: str, interval_name: str, process_query: str
) -> tuple[float, float]:
    displays: collections.defaultdict[str, dict[str, str]] = collections.defaultdict(dict)
    raw_values: collections.defaultdict[str, dict[str, str]] = collections.defaultdict(dict)
    starts: collections.defaultdict[tuple[str, str], list[float]] = (
        collections.defaultdict(list)
    )
    intervals: list[tuple[float, float]] = []
    seen: set[tuple[str, str, str, str, float]] = set()
    process_pids: dict[str, str] = {}
    process_pattern = re.compile(re.escape(process_query), re.IGNORECASE)

    def value(element: ET.Element | None, *, raw: bool = False) -> str | None:
        if element is None:
            return None
        reference = element.get("ref")
        values = raw_values if raw else displays
        if reference is not None:
            return values[element.tag].get(reference)
        if raw:
            return (element.text or element.get("fmt", "")).strip()
        return element.get("fmt", (element.text or "").strip())

    for _, row in ET.iterparse(path, events=("end",)):
        if row.tag != "row":
            continue
        for element in row.iter():
            identifier = element.get("id")
            if identifier is None:
                continue
            displays[element.tag][identifier] = element.get("fmt", element.text or "")
            raw_values[element.tag][identifier] = element.text or element.get("fmt", "")
        for element in row.iter("process"):
            identifier = element.get("id")
            if identifier is None:
                continue
            pid_element = direct_child(element, "pid")
            pid = value(pid_element, raw=True)
            if pid:
                process_pids[identifier] = pid

        name = value(direct_child(row, "signpost-name"))
        event_type = value(direct_child(row, "event-type"))
        raw_time = value(direct_child(row, "event-time"), raw=True)
        process_element = direct_child(row, "process")
        process_display = value(process_element) or ""
        process_raw = value(process_element, raw=True) or ""
        pid_element = (
            direct_child(process_element, "pid")
            if process_element is not None
            else None
        )
        process_pid = (
            process_pids.get(process_element.get("ref", ""))
            if process_element is not None
            else None
        ) or value(pid_element, raw=True) or process_raw.strip()
        if process_query.isdigit():
            process_matches = process_pid == process_query
        else:
            process_matches = bool(
                process_pattern.search(process_display)
                or process_pattern.search(process_pid)
            )
        if (
            name != interval_name
            or event_type not in {"Begin", "End"}
            or raw_time is None
            or not raw_time.isdigit()
            or not process_matches
        ):
            row.clear()
            continue
        time = int(raw_time) / 1_000_000_000.0
        signpost_id = value(
            direct_child(row, "os-signpost-identifier"), raw=True
        ) or "missing"
        process_identity = process_pid or process_display
        identity = (process_identity, signpost_id, event_type, name, time)
        if identity in seen:
            row.clear()
            continue
        seen.add(identity)
        key = (process_identity, signpost_id)
        if event_type == "Begin":
            starts[key].append(time)
        elif starts[key]:
            start = starts[key].pop(0)
            if time >= start:
                intervals.append((start, time))
        row.clear()
    if len(intervals) != 1:
        raise SystemExit(
            f"Expected exactly one {interval_name} interval for process "
            f"{process_query}; found {len(intervals)}"
        )
    return intervals[0]


def main() -> None:
    args = parse_args()
    if args.interval:
        if not args.signposts:
            raise SystemExit("--interval requires --signposts")
        args.start, args.end = signpost_interval_bounds(
            args.signposts, args.interval, args.process
        )
    process_pattern = re.compile(re.escape(args.process), re.IGNORECASE)

    binaries: dict[str, str] = {}
    pids: dict[str, str] = {}
    times: dict[str, float] = {}
    weights: dict[str, float] = {}
    processes: dict[str, tuple[str, str]] = {}
    threads: dict[str, str] = {}
    frames: dict[str, tuple[str, str]] = {}
    stacks: dict[str, list[tuple[str, str]]] = {}

    inclusive: collections.defaultdict[tuple[str, str], float] = collections.defaultdict(float)
    inclusive_main: collections.defaultdict[tuple[str, str], float] = collections.defaultdict(float)
    leaf: collections.defaultdict[tuple[str, str], float] = collections.defaultdict(float)
    target_binaries = {"SakuraCord"}
    sample_count = 0
    sampled_milliseconds = 0.0

    for _, row in ET.iterparse(args.xml, events=("end",)):
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
                times[identifier] = float(element.text or 0) / 1_000_000_000.0
            elif element.tag == "weight":
                weights[identifier] = float(element.text or 0) / 1_000_000.0

        for element in descendants:
            identifier = element.get("id")
            if identifier is None or element.tag != "frame":
                continue
            binary_element = direct_child(element, "binary")
            if binary_element is None:
                binary_name = ""
            elif binary_element.get("ref") is not None:
                binary_name = binaries.get(binary_element.get("ref", ""), "")
            else:
                binary_name = binary_element.get("name", "")
            frames[identifier] = (element.get("name", ""), binary_name)

        for element in descendants:
            identifier = element.get("id")
            if identifier is None:
                continue
            if element.tag == "process":
                pid_element = direct_child(element, "pid")
                pid = resolved(pid_element, pids)
                processes[identifier] = (element.get("fmt", ""), str(pid or ""))
            elif element.tag == "thread":
                threads[identifier] = element.get("fmt", "")
            elif element.tag == "tagged-backtrace":
                stack: list[tuple[str, str]] = []
                for frame in element:
                    if frame.tag != "frame":
                        continue
                    if frame.get("ref") is not None:
                        value = frames.get(frame.get("ref", ""))
                    else:
                        value = frames.get(frame.get("id", ""))
                    if value is not None:
                        stack.append(value)
                stacks[identifier] = stack

        process = resolved(direct_child(row, "process"), processes)
        if process is not None:
            process_name, pid = process
            matches = (
                pid == args.process
                if args.process.isdigit()
                else process_pattern.search(process_name) or process_pattern.search(pid)
            )
            sample_time = resolved(direct_child(row, "sample-time"), times)
            if matches and sample_time is not None and args.start <= sample_time < args.end:
                stack = resolved(direct_child(row, "tagged-backtrace"), stacks)
                if stack:
                    target_binaries.add(re.sub(r" \(\d+\)$", "", process_name))
                    selected = (
                        [frame for frame in stack if frame[1] in target_binaries]
                        if args.app_only
                        else stack
                    )
                    if selected:
                        weight = resolved(direct_child(row, "weight"), weights) or 1.0
                        thread = resolved(direct_child(row, "thread"), threads) or ""
                        sample_count += 1
                        sampled_milliseconds += weight
                        leaf[selected[0]] += weight
                        for frame in dict.fromkeys(selected):
                            inclusive[frame] += weight
                            if thread.startswith("Main Thread"):
                                inclusive_main[frame] += weight

        row.clear()

    if sample_count == 0:
        raise SystemExit(
            f"No Time Profiler samples for process {args.process} in the requested window"
        )

    print(f"process\t{args.process}")
    print(f"window\t{args.start:.6f}...{args.end:.6f} s")
    print(f"samples\t{sample_count}")
    print(f"sampled\t{sampled_milliseconds:.3f} ms")
    print()
    print_table("Inclusive", inclusive, args.limit)
    print()
    print_table("Inclusive main thread", inclusive_main, args.limit)
    print()
    print_table("Leaf", leaf, args.limit)


if __name__ == "__main__":
    main()
