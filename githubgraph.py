#!/usr/bin/env python3
"""Fetch a GitHub contribution graph straight from github.com (no third-party cache).

Usage: githubgraph.py <user>
Prints {"contributions": [{"date", "count", "level"}, ...], "total": N} on stdout.
"""
import json
import re
import sys
import urllib.request


def main():
    user = sys.argv[1]
    req = urllib.request.Request(
        "https://github.com/users/%s/contributions" % user,
        headers={"User-Agent": "Mozilla/5.0 (noctalia-dashboard)", "Accept": "text/html"},
    )
    html = urllib.request.urlopen(req, timeout=20).read().decode("utf-8", "replace")
    counts = {}
    for m in re.finditer(r"<tool-tip[^>]*\sfor=\"([^\"]+)\"[^>]*>([^<]*)</tool-tip>", html):
        n = re.match(r"(\d+)\s+contribution", m.group(2).strip())
        counts[m.group(1)] = int(n.group(1)) if n else 0
    days = []
    for m in re.finditer(r"<td\b[^>]*>", html):
        tag = m.group(0)
        d = re.search(r"data-date=\"(\d{4}-\d{2}-\d{2})\"", tag)
        if not d:
            continue
        i = re.search(r"\bid=\"([^\"]+)\"", tag)
        lv = re.search(r"data-level=\"(\d)\"", tag)
        days.append({
            "date": d.group(1),
            "count": counts.get(i.group(1), 0) if i else 0,
            "level": int(lv.group(1)) if lv else 0,
        })
    days.sort(key=lambda x: x["date"])
    if not days:
        sys.exit(2)
    print(json.dumps({"contributions": days, "total": sum(x["count"] for x in days)}))


main()
