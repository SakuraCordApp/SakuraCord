#!/usr/bin/env python3
"""Frame-by-frame toolbar item report for a side chat motion recording.

For each action in a recording from `script/motion_benchmark.sh`, follows
every window toolbar item through the display-link frames from just before
the action until the next one, and reports when it appears, disappears or
moves. A change is flagged when it happens after the first frame that
reflects the action (the item set should change once, with the action), when
an item jumps more than --jump-pt in one frame, or when it is still moving
after --late-ms (a late reposition).

Usage: motion_toolbar_report.py RECORDING.json [--group NAME] [--markdown]
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field


@dataclass
class ItemTrack:
    identifier: str
    events: list[str] = field(default_factory=list)
    flags: list[str] = field(default_factory=list)


def short(identifier: str) -> str:
    # SwiftUI gives unnamed items UUID identifiers; keep them recognisable.
    if len(identifier) == 36 and identifier.count("-") == 4:
        return f"unnamed-{identifier[:4]}"
    return identifier.replace("NSToolbar", "").replace("Item", "")


def analyze(recording: dict, jump_pt: float, late_ms: float) -> list[tuple[dict, list[ItemTrack]]]:
    frames = recording["frames"]
    identifiers = recording.get("toolbarItemIdentifiers", [])
    actions = sorted(recording["actions"], key=lambda a: a["time"])
    results = []
    for index, action in enumerate(actions):
        start = action["time"]
        end = actions[index + 1]["time"] if index + 1 < len(actions) else frames[-1]["time"] + 1
        window = [f for f in frames if start - 0.02 <= f["time"] < end]
        if len(window) < 2:
            continue
        tracks: dict[int, ItemTrack] = {}
        first_change_frame: int | None = None
        previous = {int(item[0]): item for item in window[0].get("toolbarItems", [])}
        for number, frame in enumerate(window[1:], start=1):
            current = {int(item[0]): item for item in frame.get("toolbarItems", [])}
            offset = (frame["time"] - start) * 1000
            label = f"f{number} (+{offset:.0f} ms)"
            for key in sorted(set(previous) | set(current)):
                track = tracks.setdefault(key, ItemTrack(short(identifiers[key])))
                before, after = previous.get(key), current.get(key)
                change = None
                if before is None:
                    change = f"appears at {label}, x={after[1]:.0f}"
                elif after is None:
                    change = f"disappears at {label}"
                else:
                    dx = after[1] - before[1]
                    dw = after[3] - before[3]
                    if abs(dx) > 0.5 or abs(dw) > 0.5:
                        change = f"moves {dx:+.0f} pt" + (f", width {dw:+.0f}" if abs(dw) > 0.5 else "") + f" at {label}"
                        if abs(dx) > jump_pt:
                            track.flags.append(f"jump {dx:+.0f} pt at {label}")
                if change is None:
                    continue
                track.events.append(change)
                if first_change_frame is None:
                    first_change_frame = number
                elif number > first_change_frame and ("appears" in change or "disappears" in change):
                    track.flags.append(f"{change.split(' at ')[0]} after the first changed frame")
                if offset > late_ms:
                    track.flags.append(f"late change at {label}")
            previous = current
        results.append((action, list(tracks.values())))
    return results


def render(results, group: str | None, markdown: bool) -> str:
    lines = []
    for action, tracks in results:
        name = action["name"] + (f" [{action['variant']}]" if action.get("variant") else "")
        if group and group not in name:
            continue
        changed = [t for t in tracks if t.events]
        lines.append(f"\n{'### ' if markdown else '== '}{name} (cycle {action.get('cycle', 0)})")
        if not changed:
            lines.append("No toolbar item changed.")
            continue
        if markdown:
            lines.append("| item | what happens | problems |")
            lines.append("|---|---|---|")
        for track in changed:
            events = "; ".join(track.events[:6]) + (f"; +{len(track.events) - 6} more" if len(track.events) > 6 else "")
            flags = "; ".join(dict.fromkeys(track.flags)) or "–"
            if markdown:
                lines.append(f"| {track.identifier} | {events} | {flags} |")
            else:
                lines.append(f"  {track.identifier}: {events}  [{flags}]")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("recording")
    parser.add_argument("--group", help="only actions whose name contains this text")
    parser.add_argument("--markdown", action="store_true")
    parser.add_argument("--jump-pt", type=float, default=24.0)
    parser.add_argument("--late-ms", type=float, default=450.0)
    parser.add_argument("--first-cycle-only", action="store_true")
    args = parser.parse_args()
    with open(args.recording) as handle:
        recording = json.load(handle)
    if "toolbarItemIdentifiers" not in recording:
        print("This recording has no toolbar item frames.", file=sys.stderr)
        return 2
    results = analyze(recording, args.jump_pt, args.late_ms)
    if args.first_cycle_only:
        seen = set()
        kept = []
        for action, tracks in results:
            key = (action["name"], action.get("variant"))
            if key not in seen:
                seen.add(key)
                kept.append((action, tracks))
        results = kept
    print(render(results, args.group, args.markdown))
    return 0


if __name__ == "__main__":
    sys.exit(main())
