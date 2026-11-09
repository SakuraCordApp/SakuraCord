#!/usr/bin/env python3
"""Bound a test process and retain its output and macOS hang samples."""

import argparse
import errno
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time


def session_processes(pid):
    listing = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,pgid=,stat=,etime=,comm="], text=True,
    )
    rows = [line for line in listing.splitlines() if len(line.split()) >= 6]
    # The launcher leads its own session. SwiftPM starts its test helper in a
    # separate process group of that session, which the helper keeps even when
    # the launcher exits and it is reparented.
    return [row for row in rows if in_session(int(row.split()[0]), pid)]


def in_session(pid, session):
    try:
        return os.getsid(pid) == session
    except OSError:
        # The process exited, or belongs to another user.
        return False


def signal_group(pid, sig):
    try:
        os.killpg(pid, sig)
        return True
    except (ProcessLookupError, PermissionError):
        # macOS reports EPERM for a group that holds only unreaped zombies.
        return False


def stop(process):
    # The launcher may have exited while a child still owns the output pipe.
    groups = {process.pid} | {int(row.split()[2]) for row in session_processes(process.pid)}
    if any([signal_group(group, signal.SIGTERM) for group in groups]):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            process.poll()
            if not any(signal_group(group, 0) for group in groups):
                break
            time.sleep(0.1)
        for group in groups:
            signal_group(group, signal.SIGKILL)
    # Like ps and sample, a killed process always finishes, but a starved
    # machine can take longer than any fixed limit.
    process.wait()


def sample(pid, path):
    # A loaded machine can stretch sample's attach, sampling and symbol phases
    # far beyond their nominal length, and killing it discards the report.
    # SIGINT ends sampling and still writes the report, but only while sampling:
    # after the stderr announcement, and before a requested duration far longer
    # than the two seconds actually sampled.
    with subprocess.Popen(["/usr/bin/sample", pid, "60", "-file", str(path)],
                          stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                          text=True) as sampler:
        try:
            if sampler.stderr.readline().startswith("Sampling process"):
                try:
                    sampler.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    sampler.send_signal(signal.SIGINT)
            _, error = sampler.communicate()
        except BaseException:
            # A cancelled run must reach test-host cleanup without waiting
            # for the sampler to finish.
            sampler.kill()
            raise
    if not path.exists():
        print(f"Could not sample PID {pid}: {error.strip()}", flush=True)


def diagnose(process, directory):
    events = directory / "events.jsonl"
    if events.exists():
        pending = set()
        for line in events.read_text(errors="replace").splitlines():
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue  # The running test host may still be writing its last event.
            event = record.get("payload", {})
            if record.get("kind") == "event" and "testID" in event:
                if event.get("kind") == "testStarted":
                    pending.add(event["testID"])
                elif event.get("kind") == "testEnded":
                    pending.discard(event["testID"])
        print("Tests started without an end event:\n" + "\n".join(sorted(pending)), flush=True)
    try:
        rows = session_processes(process.pid)
        (directory / "processes.txt").write_text("\n".join(rows) + "\n")
        print("\n".join(rows), flush=True)
        # Sample up to six children before the SwiftPM launcher.
        for row in sorted(rows, key=lambda row: int(row.split()[0]) == process.pid)[:6]:
            pid = row.split()[0]
            path = directory / f"{pid}.sample.txt"
            try:
                sample(pid, path)
            except OSError as error:
                print(f"Could not sample PID {pid}: {error}", flush=True)
            if path.exists():
                print(f"Stack sample: {path}", flush=True)
                print("\n".join(path.read_text(errors="replace").splitlines()[:80]), flush=True)
    except (OSError, subprocess.SubprocessError) as error:
        print(f"Could not collect process diagnostics: {error}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=float, default=180)
    parser.add_argument("--events", action="store_true", help="Record Swift Testing's event stream")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not 0 < args.timeout_seconds < float("inf"):
        parser.error("a command and finite positive timeout are required")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix=f"{args.label}-", dir=args.output_dir)).resolve()
    if args.events:
        command += ["--event-stream-version", "0",
                    "--event-stream-output-path", str(directory / "events.jsonl")]

    # A terminal makes SwiftPM flush its own console output as it arrives.
    master, slave = pty.openpty()
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=slave,
                                   stderr=slave, start_new_session=True)
    finally:
        os.close(slave)

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)

    started = time.monotonic()
    heartbeat = started + 30
    print(f"Tests: {args.label} (PID {process.pid}, limit {args.timeout_seconds:g}s)", flush=True)
    print(f"Diagnostics: {directory}", flush=True)
    try:
        with (directory / "console.log").open("wb") as log:
            output_open = True
            while output_open or process.poll() is None:
                now = time.monotonic()
                if now - started >= args.timeout_seconds:
                    print(f"::error::{args.label} exceeded {args.timeout_seconds:g}s; capturing stacks", flush=True)
                    try:
                        diagnose(process, directory)
                    except OSError as error:
                        print(f"Could not read test events: {error}", flush=True)
                    return 124
                if now >= heartbeat:
                    print(f"Tests: {args.label} still running after {int(now - started)}s", flush=True)
                    heartbeat = now + 30
                if not output_open:
                    time.sleep(0.1)
                    continue
                ready, _, _ = select.select([master], [], [], 0.2)
                if not ready:
                    continue
                try:
                    data = os.read(master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    data = b""
                if not data:
                    output_open = False
                    continue
                log.write(data)
                log.flush()
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
        result = process.wait()
        return result if result >= 0 else 128 - result
    finally:
        # A second cancellation must not interrupt cleanup and orphan test hosts.
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, signal.SIG_IGN)
        stop(process)
        os.close(master)


if __name__ == "__main__":
    sys.exit(main())
