#!/usr/bin/env python3
"""Record Linux process resources without entering the target's event loop.

Uses only Python's standard library and /proc. Each log line is a JSON object;
the collector never signals, attaches a debugger to, or pauses the target.
"""

import argparse
import datetime
import json
import logging
import logging.handlers
import math
import os
from pathlib import Path
import signal
import sys
import threading
import time


def parse_stat(text):
    """Extract stable fields from /proc/PID/stat (also used for thread stat).

    The parenthesized command name can contain whitespace and parentheses.
    Splitting the whole line on spaces would therefore shift field numbers.
    Index zero below corresponds to field 3 in the Linux proc stat format.
    """
    fields = text[text.rindex(")") + 2:].split()
    return {
        "state": fields[0],
        "minor_faults": int(fields[7]),
        "major_faults": int(fields[9]),
        "user_ticks": int(fields[11]),
        "system_ticks": int(fields[12]),
        "thread_count": int(fields[17]),
        "start_ticks": int(fields[19]),
        "virtual_bytes": int(fields[20]),
        "resident_pages": int(fields[21]),
    }


def parse_fields(text):
    """Read colon-separated proc fields, preserving values and their units."""
    return dict(line.split(":", 1) for line in text.splitlines() if ":" in line)


def read_status(path):
    """Collect memory and context-switch counters from a process or thread.

    Linux labels memory values as kB, but reports units of 1024 bytes. Missing
    fields remain absent rather than being mistaken for a measured zero.
    """
    fields = parse_fields(path.read_text())
    result = {}
    for source, destination in {
        "VmRSS": "rss_bytes",
        "VmHWM": "peak_rss_bytes",
        "VmSize": "virtual_bytes",
        "VmSwap": "swap_bytes",
        "RssAnon": "anonymous_rss_bytes",
        "RssFile": "file_rss_bytes",
    }.items():
        if source in fields:
            result[destination] = int(fields[source].split()[0]) * 1024
    for source in ("voluntary_ctxt_switches", "nonvoluntary_ctxt_switches"):
        if source in fields:
            result[source] = int(fields[source])
    return result


def read_io(path):
    """Read cumulative I/O counters; access may require the target's user ID.

    read_bytes/write_bytes describe storage I/O accounting; rchar/wchar count
    bytes passed through read/write system calls, including cached I/O.
    """
    return {key: int(value) for key, value in parse_fields(path.read_text()).items()}


def optional_read(errors, label, operation):
    """Keep sampling when permissions or a disappearing thread deny a field.

    Explicit errors distinguish unavailable observations from actual zeroes.
    A final process identity check separately detects process exit or PID reuse.
    """
    try:
        return operation()
    except (OSError, ValueError, IndexError) as error:
        errors[label] = str(error)
        return None


def add_rates(current, previous, elapsed, ticks_per_second):
    """Add interval CPU and I/O rates only when two matching samples exist.

    CPU is expressed relative to one logical CPU: 100% means one CPU fully
    occupied, and a multithreaded process can exceed 100%. Monotonic elapsed
    time avoids negative or inflated rates when the wall clock is adjusted.
    """
    current["cpu_percent"] = None
    if previous is None or elapsed <= 0 or current["start_ticks"] != previous["start_ticks"]:
        return
    ticks = sum(current[key] - previous[key] for key in ("user_ticks", "system_ticks"))
    if ticks >= 0:
        current["cpu_percent"] = round(100 * ticks / ticks_per_second / elapsed, 3)
    if current.get("io") is not None and previous.get("io") is not None:
        current["io_per_second"] = {
            key: round((value - previous["io"][key]) / elapsed, 3)
            for key, value in current["io"].items()
            if key in previous["io"] and value >= previous["io"][key]
        }


class TargetEnded(Exception):
    """Signal that this process incarnation can no longer be sampled."""


class Collector:
    """Maintain the target identity and previous observations for rate math."""

    def __init__(self, pid, include_threads=True):
        """Bind to a PID plus its kernel start time, never just the PID alone."""
        self.root = Path("/proc") / str(pid)
        self.pid = pid
        self.include_threads = include_threads
        self.ticks_per_second = os.sysconf("SC_CLK_TCK")
        self.page_size = os.sysconf("SC_PAGE_SIZE")
        self.start_ticks = parse_stat((self.root / "stat").read_text())["start_ticks"]
        self.previous = None
        self.previous_time = None

    def identity(self):
        """Reject exited, zombie, or replaced processes before using a sample."""
        try:
            stat = parse_stat((self.root / "stat").read_text())
        except (FileNotFoundError, ProcessLookupError):
            raise TargetEnded("process exited") from None
        if stat["start_ticks"] != self.start_ticks:
            raise TargetEnded("PID was reused")
        if stat["state"] in ("Z", "X", "x"):
            raise TargetEnded("process exited (zombie or dead)")
        return stat

    def sample(self):
        """Take a best-effort snapshot and calculate rates from the prior one.

        /proc files are read sequentially, not atomically. Check identity again
        afterward so a process restart cannot mix two incarnations in a record.
        Per-thread counters and wait channels help distinguish busy loops from
        sleeping workers; wait channels are hints, not native stack traces.
        """
        now = time.monotonic()
        errors = {}
        process = self.identity()
        process["rss_bytes"] = process.pop("resident_pages") * self.page_size
        process["status"] = optional_read(errors, "status", lambda: read_status(self.root / "status"))
        process["io"] = optional_read(errors, "io", lambda: read_io(self.root / "io"))
        process["fd_count"] = optional_read(errors, "fd", lambda: len(list((self.root / "fd").iterdir())))
        elapsed = 0 if self.previous_time is None else now - self.previous_time
        add_rates(process, self.previous, elapsed, self.ticks_per_second)

        if self.include_threads:
            process["threads"] = {}
            paths = optional_read(errors, "task", lambda: list((self.root / "task").iterdir()))
            previous_threads = (self.previous or {}).get("threads", {})
            for path in sorted(paths or [], key=lambda item: int(item.name)):
                label = "thread:" + path.name
                thread = optional_read(errors, label, lambda: parse_stat((path / "stat").read_text()))
                if thread is None:
                    continue
                # Thread stat repeats process memory figures. Retain only
                # thread-specific state, CPU, faults, and identity here.
                for key in ("resident_pages", "virtual_bytes", "thread_count"):
                    thread.pop(key)
                thread["wchan"] = optional_read(errors, label + ":wchan", lambda: (path / "wchan").read_text().strip())
                status = optional_read(errors, label + ":status", lambda: read_status(path / "status"))
                thread["context_switches"] = None if status is None else {
                    key: value for key, value in status.items() if key.endswith("ctxt_switches")
                }
                add_rates(thread, previous_threads.get(path.name), elapsed, self.ticks_per_second)
                process["threads"][path.name] = thread

        self.identity()
        self.previous = process
        self.previous_time = now
        return {"event": "sample", "pid": self.pid, "elapsed_seconds": elapsed or None,
                "process": process, "errors": errors}


class StrictRotatingHandler(logging.handlers.RotatingFileHandler):
    """Fail visibly on disk errors instead of silently losing monitoring data."""

    def handleError(self, record):
        """Propagate write/rotation failures to the command's exit handler."""
        raise


def positive_integer(value):
    """Validate strictly positive CLI quantities such as PID and log limits."""
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return number


def positive_interval(value):
    """Reject non-finite or non-positive intervals before scheduling waits."""
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be finite and greater than zero")
    return number


def main(argv=None):
    """Run sampling until the target exits, a signal arrives, or count is met."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pid", type=positive_integer, help="PID of the TclWire process")
    parser.add_argument("--output", required=True, type=Path, help="JSON Lines log (parent directory must exist)")
    parser.add_argument("--interval", type=positive_interval, default=5.0, help="sample interval in seconds (default: 5)")
    parser.add_argument("--max-mib", type=positive_integer, default=20, help="rotate at this many MiB (default: 20)")
    parser.add_argument("--backups", type=positive_integer, default=5, help="rotated files retained (default: 5)")
    parser.add_argument("--count", type=positive_integer, help="stop after this many samples")
    parser.add_argument("--no-threads", action="store_true", help="omit per-thread details to reduce overhead and log volume")
    args = parser.parse_args(argv)
    if not sys.platform.startswith("linux"):
        parser.error("this collector requires Linux /proc")

    # Restrict newly created logs to this user. Existing files retain their
    # permissions. Never record command-line arguments or the environment.
    os.umask(0o077)
    collector = Collector(args.pid, not args.no_threads)
    handler = StrictRotatingHandler(args.output, maxBytes=args.max_mib * 1024 * 1024,
                                    backupCount=args.backups, encoding="utf-8")
    logger = logging.Logger("process-monitor", level=logging.INFO)
    logger.addHandler(handler)

    def emit(record):
        """Write one immediately flushed record with an unambiguous UTC time."""
        record["timestamp"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        logger.info(json.dumps(record, separators=(",", ":"), allow_nan=False))

    stopped = threading.Event()

    def request_stop(signum, frame):
        """Interrupt a scheduled wait without touching the monitored process."""
        stopped.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    try:
        emit({"event": "start", "schema_version": 1, "pid": args.pid,
              "start_ticks": collector.start_ticks, "interval_seconds": args.interval,
              "clock_ticks_per_second": collector.ticks_per_second,
              "logical_cpus": os.cpu_count(), "include_threads": not args.no_threads})
        count = 0
        reason = "signal"
        deadline = time.monotonic()
        while not stopped.is_set():
            try:
                emit(collector.sample())
            except TargetEnded as error:
                reason = str(error)
                break
            count += 1
            if args.count is not None and count >= args.count:
                reason = "sample limit reached"
                break
            # Keep a monotonic schedule, but skip missed intervals rather than
            # issuing a burst of samples after a slow filesystem operation.
            deadline += args.interval
            now = time.monotonic()
            if deadline <= now:
                deadline = now + args.interval
            stopped.wait(deadline - now)
        emit({"event": "stop", "pid": args.pid, "reason": reason, "samples": count})
    finally:
        handler.close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, IndexError) as error:
        print("process monitor: " + str(error), file=sys.stderr)
        sys.exit(1)
