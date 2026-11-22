#!/usr/bin/env python3
"""Sample recent CPU and resident memory for executable groups on Linux."""

from collections import defaultdict
import json
import os
from pathlib import Path
import time


PROC = Path("/proc")
PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")
SAMPLE_SECONDS = 0.4
LIMIT = 16


def read_process(path):
    raw = (path / "stat").read_text(encoding="utf-8", errors="replace")
    # comm is parenthesized and can itself contain spaces and parentheses.
    name_start, name_end = raw.index("("), raw.rindex(")")
    fields = raw[name_end + 2:].split()
    ticks = int(fields[11]) + int(fields[12])
    start = int(fields[19])
    rss = int(fields[21]) * PAGE_SIZE
    return start, ticks, rss, raw[name_start + 1:name_end]


def snapshot(include_names=False):
    with (PROC / "stat").open(encoding="ascii") as stat:
        # The first eight counters already include guest time.
        total_ticks = sum(map(int, stat.readline().split()[1:9]))
    processes = {}
    own_pid = str(os.getpid())
    for entry in PROC.iterdir():
        pid = entry.name
        if not pid.isdecimal() or pid == own_pid:
            continue
        try:
            start, ticks, rss, name = read_process(entry)
        except (OSError, ValueError, IndexError):
            continue
        if rss <= 0:
            continue
        if include_names:
            try:
                executable = os.path.basename(os.readlink(entry / "exe"))
                name = executable.removesuffix(" (deleted)") or name
            except OSError:
                pass
        processes[pid, start] = (ticks, rss, name)
    return total_ticks, processes


def summarize(before, after, elapsed_ticks):
    groups = defaultdict(lambda: {"cpu": 0.0, "rss": 0, "count": 0})
    for identity, (ticks, rss, name) in after.items():
        name = " ".join(name.split())[:96] or "Unknown process"
        group = groups[name]
        if identity in before and elapsed_ticks > 0:
            group["cpu"] += 100 * max(0, ticks - before[identity][0]) / elapsed_ticks
        group["rss"] += rss
        group["count"] += 1

    rows = [{"name": name, **values} for name, values in groups.items()]
    return {
        "cpu": sorted(rows, key=lambda row: (-row["cpu"], -row["rss"], row["name"]))[:LIMIT],
        "ram": sorted(rows, key=lambda row: (-row["rss"], -row["cpu"], row["name"]))[:LIMIT],
    }


def main():
    before_at, before = snapshot()
    time.sleep(SAMPLE_SECONDS)
    after_at, after = snapshot(include_names=True)
    print(json.dumps(summarize(before, after, after_at - before_at)))


if __name__ == "__main__":
    main()
