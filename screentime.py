#!/usr/bin/env python3
"""Summarise Noctalia's screen_time.json for the dashboard.

Usage: screentime.py <path-to-screen_time.json>
Prints one small JSON object on stdout. The file layout is undocumented, so this
is structure-agnostic: it finds every node that belongs to one of the last 7
dates, then classifies each number by its key path:
  * a key "0".."23" (or a 24-long numeric list) is an hour bucket
  * the last other string key (not a date / generic word) is the app name
"""
import json
import os
import re
import sys
import time

GENERIC = {
    "total", "totalSeconds", "total_seconds", "seconds", "secs", "duration", "time", "ms",
    "apps", "hours", "hourly", "daily", "days", "usage", "sessions", "history", "data",
    "version", "entries",
}
AGGREGATE = {"total", "totalSeconds", "total_seconds", "sum"}
NAME_FIELDS = ("app", "app_id", "appId", "name", "id", "class", "title")
VALUE_FIELDS = ("seconds", "secs", "duration", "time", "ms")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
HOUR_RE = re.compile(r"^\d{1,2}$")


def classify(k):
    if isinstance(k, str):
        if k.startswith("H:"):
            return int(k[2:])
        if HOUR_RE.match(k) and int(k) <= 23:
            return int(k)
        if DATE_RE.match(k):
            return "date"
        if k in GENERIC:
            return "generic"
        return "app"
    return "other"


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


class Acc:
    def __init__(self):
        self.total = 0.0
        self.apps = {}
        self.hours = {}
        self.hour_apps = {}  # hour -> app -> seconds

    def add(self, path, v):
        app = hour = None
        for k in reversed(path):
            c = classify(k)
            if isinstance(c, int):
                if hour is None:
                    hour = c
            elif c == "app" and app is None:
                app = k
        self.total += v
        if app is not None:
            self.apps[app] = self.apps.get(app, 0) + v
        if hour is not None:
            self.hours[hour] = self.hours.get(hour, 0) + v
            ha = self.hour_apps.setdefault(hour, {})
            key = app if app is not None else "_other"
            ha[key] = ha.get(key, 0) + v


def walk(v, path, acc, depth=0):
    if is_num(v):
        acc.add(path, v)
        return
    if depth > 8:
        return
    if isinstance(v, list):
        if len(v) == 24 and all(is_num(x) for x in v):
            for i, x in enumerate(v):
                acc.add(path + ["H:%d" % i], x)
            return
        for x in v:
            walk(x, path, acc, depth + 1)
        return
    if not isinstance(v, dict):
        return
    name = next((v[f] for f in NAME_FIELDS if isinstance(v.get(f), str)), None)
    value = next((v[f] for f in VALUE_FIELDS if is_num(v.get(f))), None)
    if name is not None and value is not None:
        acc.add(path + [name], value)
        return
    for k, x in v.items():
        if k in AGGREGATE:
            continue
        walk(x, path + [k], acc, depth + 1)


def scan(v, path, date_set, found, depth=0):
    if depth > 5:
        return
    if isinstance(v, dict):
        items = v.items()
    elif isinstance(v, list):
        items = ((None, x) for x in v)
    else:
        return
    for k, x in items:
        if isinstance(k, str) and k in date_set:
            found.append((k, x, list(path)))
        elif isinstance(x, dict) and (x.get("date") in date_set or x.get("day") in date_set):
            found.append((x.get("date") or x.get("day"), x, list(path)))
        elif isinstance(x, (dict, list)):
            scan(x, path + ([k] if isinstance(k, str) else []), date_set, found, depth + 1)


APP_DIRS = [
    os.path.expanduser("~/.local/share/applications"),
    "/usr/share/applications",
    "/usr/local/share/applications",
    "/var/lib/flatpak/exports/share/applications",
    os.path.expanduser("~/.local/share/flatpak/exports/share/applications"),
]


def desktop_icons():
    """Map lower-cased app Name / StartupWMClass / desktop-file stem -> Icon value."""
    idx = {}
    for d in APP_DIRS:
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for fn in names:
            if not fn.endswith(".desktop"):
                continue
            name = icon = wm = None
            try:
                with open(os.path.join(d, fn), "r", encoding="utf-8", errors="replace") as fh:
                    in_entry = False
                    for line in fh:
                        line = line.strip()
                        if line.startswith("["):
                            if in_entry:
                                break
                            in_entry = line == "[Desktop Entry]"
                            continue
                        if not in_entry:
                            continue
                        if line.startswith("Name=") and name is None:
                            name = line[5:]
                        elif line.startswith("Icon=") and icon is None:
                            icon = line[5:]
                        elif line.startswith("StartupWMClass=") and wm is None:
                            wm = line[15:]
            except OSError:
                continue
            if not icon:
                continue
            for key in (name, wm, fn[:-8]):
                if key:
                    idx.setdefault(key.lower(), icon)
    return idx


def main():
    path = sys.argv[1]
    try:
        raw = open(path, "r", encoding="utf-8", errors="replace").read()
    except OSError:
        print(json.dumps({"ok": False, "missing": True}))
        return
    sample = raw[:260]
    try:
        data = json.loads(raw)
    except ValueError:
        print(json.dumps({"ok": False, "sample": sample}))
        return

    now = time.time()
    dates = []
    for i in range(13, -1, -1):  # last 14 days, oldest first
        t = now - i * 86400
        dates.append((time.strftime("%Y-%m-%d", time.localtime(t)), time.strftime("%a", time.localtime(t))))
    date_set = {d for d, _ in dates}

    found = []
    scan(data, [], date_set, found)
    if not found:
        print(json.dumps({"ok": False, "sample": sample}))
        return

    accs = {}
    for date, node, prefix in found:
        if isinstance(node, dict) and isinstance(node.get("app_hourly"), dict):
            node = node["app_hourly"]  # Noctalia's layout: day -> app_hourly -> app -> 24 hourly values
        walk(node, prefix, accs.setdefault(date, Acc()))

    # anything above 48h of seconds in a single day must be milliseconds
    div = 1000 if max(a.total for a in accs.values()) > 172800 else 1

    # rank apps over the whole window; the top ones get their own colour, the rest become "_other"
    totals = {}
    for a in accs.values():
        for app, v in a.apps.items():
            totals[app] = totals.get(app, 0) + v
    ranked = [k for k, _ in sorted(totals.items(), key=lambda kv: kv[1], reverse=True)]
    top = ranked[:8]
    top_set = set(top)

    def fold(by):
        out = {}
        for app, v in by.items():
            key = app if app in top_set else "_other"
            sec = int(v / div)
            if sec > 0:
                out[key] = out.get(key, 0) + sec
        return out

    days = []
    for d, lab in dates:
        a = accs.get(d)
        days.append({"d": d, "label": lab, "sec": int(a.total / div) if a else 0, "by": fold(a.apps) if a else {}})

    today = accs.get(dates[-1][0])
    hours = []
    if today is not None and today.hour_apps:
        for h in range(24):
            by = fold(today.hour_apps.get(h, {}))
            hours.append({"sec": sum(by.values()), "by": by})

    icons = desktop_icons() if top else {}
    print(json.dumps({
        "ok": True,
        "sec": days[-1]["sec"],
        "apps": [{"id": k, "name": k, "icon": icons.get(k.lower(), "")} for k in top],
        "days": days,
        "hours": hours,
    }))


if __name__ == "__main__":
    main()
