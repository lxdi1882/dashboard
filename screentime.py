#!/usr/bin/env python3
"""Summarise Noctalia's screen_time.json for the dashboard.

Usage: screentime.py <path-to-screen_time.json>
Prints one small JSON object on stdout. The file layout is undocumented, so this
is structure-agnostic: it finds every node that belongs to one of the last 14
dates, then classifies each number by its key path:
  * a key "0".."23" (or a 24-long numeric list) is an hour bucket
  * the last other string key (not a date / generic word) is the app name
"""
from datetime import date as calendar_date, timedelta
import hashlib
import json
import os
from pathlib import Path
import re
import sys

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
BRAVE_APP = re.compile(r"(?:^|[.])brave(?:$|[-.])")
SITE_PREFIX = "site:"
BRAVE_REMAINDER = "browser:brave-other"
BROWSER_APP = re.compile(
    r"(?:^|[.])(?:brave|chromium|chrome|firefox|librewolf|waterfox|floorp|vivaldi|opera|"
    r"microsoft-edge|zen-browser|qutebrowser|epiphany|falkon|thorium|ungoogled-chromium)"
    r"(?:$|[-.])"
)


def is_browser(app):
    return BROWSER_APP.search(app.lower()) is not None


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


SITE_SUFFIXES = {"com", "org", "net", "edu", "gov", "mil", "info", "biz", "dev", "app", "io", "ai", "tv",
                 "xyz", "online", "tech", "shop", "cloud", "site", "blog"}
COUNTRY_SUFFIXES = {"co", "com", "net", "org", "gov", "edu", "ac"}


def site_label(domain):
    label = re.sub(r"^www[0-9]*\.", "", domain)
    parts = label.split(".")
    if len(parts) >= 2 and (parts[-1] in SITE_SUFFIXES or re.fullmatch(r"[a-z]{2}", parts[-1])):
        if len(parts) >= 3 and len(parts[-1]) == 2 and parts[-2] in COUNTRY_SUFFIXES:
            parts.pop()
        parts.pop()
    label = ".".join(parts) or domain
    return label[:1].upper() + label[1:]


def load_sites(directory, dates):
    """Read aggregate domain durations exported by the optional Brave companion."""
    days = {day: {} for day, _ in dates}
    profiles = []
    directory = Path(directory)
    for path in directory.glob("*.json"):
        try:
            profile = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(profile, dict):
            continue
        profiles.append(path.stem)
        for day, by_domain in profile.items():
            if day not in days or not isinstance(by_domain, dict):
                continue
            for domain, duration in by_domain.items():
                if type(duration) is int and duration > 0 and re.fullmatch(r"[a-z0-9.-]{1,253}", domain):
                    days[day][domain] = days[day].get(domain, 0) + duration
    if not profiles:
        return None, {}, None

    icons = {}

    def icon_for(domain):
        if domain not in icons:
            name = hashlib.sha256(domain.encode("ascii")).hexdigest() + ".png"
            paths = (directory / "icons" / profile / name for profile in profiles)
            icons[domain] = next((str(path) for path in paths if path.is_file()), "")
        return icons[domain]

    def trend_for(domain):
        return {
            "seconds": [days[day].get(domain, 0) // 1000 for day, _ in dates],
            "icon": icon_for(domain),
            "name": site_label(domain),
        }

    def ranked(values):
        rows = []
        for domain, ms in sorted(values.items(), key=lambda item: (-item[1], item[0]))[:10]:
            if ms < 1000:
                continue
            rows.append({"domain": domain, "name": site_label(domain), "sec": ms // 1000, "icon": icon_for(domain)})
        return rows

    ranges, range_totals = {}, {}
    for key, length in (("today", 1), ("7d", 7), ("14d", 14)):
        totals = {}
        for day, _ in dates[-length:]:
            for domain, ms in days[day].items():
                totals[domain] = totals.get(domain, 0) + ms
        ranges[key] = ranked(totals)
        range_totals[key] = sum(totals.values()) // 1000

    # Include exact daily totals for every listed site, even on days it ranked below the top ten.
    domains = sorted({row["domain"] for listing in ranges.values() for row in listing})
    return {
        "ranges": ranges,
        "rangeTotals": range_totals,
        "calendar": [{"date": day, "recorded": bool(days[day])} for day, _ in dates],
        "trends": {domain: trend_for(domain) for domain in domains},
    }, days, trend_for


def attribute_sites(apps, site_ms):
    """Subdivide the Brave seconds already counted in the day total."""
    brave = [app for app in apps if BRAVE_APP.search(app.lower())]
    budget = sum(apps[app] for app in brave)
    if budget <= 0:
        return apps
    total_ms = sum(site_ms.values())
    credited = min(budget, total_ms // 1000)
    result = {app: seconds for app, seconds in apps.items() if app not in brave}
    if credited > 0:
        # Cumulative rounding keeps the domain split exactly equal to the credited budget.
        cumulative_ms = 0
        allocated = 0
        for domain, duration in sorted(site_ms.items()):
            cumulative_ms += duration
            target = cumulative_ms * credited // total_ms
            if target > allocated:
                result[SITE_PREFIX + domain] = target - allocated
            allocated = target
    if budget > credited:
        result[BRAVE_REMAINDER] = budget - credited
    return result


def sum_usage(days):
    totals = {}
    for by in days:
        for item, duration in by.items():
            totals[item] = totals.get(item, 0) + duration
    return totals


def rank_usage(totals):
    return sorted(totals, key=lambda item: (-totals[item], item))


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

    today = calendar_date.today()
    recent_dates = [today - timedelta(days=i) for i in range(13, -1, -1)]
    dates = [(day.isoformat(), day.strftime("%a")) for day in recent_dates]
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

    sites, site_days, trend_for = load_sites(sys.argv[3], dates) if len(sys.argv) > 3 else (None, {}, None)

    def in_seconds(by):
        return {app: sec for app, duration in by.items() if (sec := int(duration / div)) > 0}

    raw_days = {day: in_seconds(accs[day].apps) if day in accs else {} for day, _ in dates}
    daily = {day: attribute_sites(by, site_days.get(day, {})) if sites is not None else by
             for day, by in raw_days.items()}
    mixed = any(daily[day] is not by for day, by in raw_days.items())
    ranked = rank_usage(sum_usage(daily.values()))
    raw_ranked = rank_usage(sum_usage(raw_days.values())) if mixed else ranked
    limit = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 12
    top, hourly_top = ranked[:limit], raw_ranked[:limit]
    top_set, hourly_set = set(top), set(hourly_top)

    def fold(by, keep):
        out = {}
        for item, seconds in by.items():
            key = item if item in keep else "_other"
            out[key] = out.get(key, 0) + seconds
        return out

    days = []
    hours = []
    for d, lab in dates:
        a = accs.get(d)
        day = {"d": d, "label": lab, "sec": int(a.total / div) if a else 0, "by": fold(daily[d], top_set)}
        if a is not None and a.hour_apps:
            if d == dates[-1][0]:
                for h in range(24):
                    by = fold(in_seconds(a.hour_apps.get(h, {})), hourly_set)
                    hours.append({"sec": sum(by.values()), "by": by})
            else:
                # Send only recorded buckets. The dashboard fills the gaps with zeroes.
                day["hours"] = {
                    f"h{h}": by for h, apps in a.hour_apps.items()
                    if 0 <= h < 24 and (by := fold(in_seconds(apps), hourly_set))
                }
        days.append(day)

    icons = desktop_icons() if top or hourly_top else {}
    brave = next((app for app in raw_ranked if BRAVE_APP.search(app.lower())), "")

    def metadata(item):
        if sites is not None and item.startswith(SITE_PREFIX):
            domain = item[len(SITE_PREFIX):]
            if domain not in sites["trends"]:
                sites["trends"][domain] = trend_for(domain)
            trend = sites["trends"][domain]
            return {"id": item, "name": trend["name"], "domain": domain, "icon": trend["icon"]}
        if item == BRAVE_REMAINDER:
            return {"id": item, "name": "Other Brave time", "icon": icons.get(brave.lower(), brave)}
        return {"id": item, "name": item, "icon": icons.get(item.lower(), "")}

    scopes, scope_metadata = {}, {}
    if mixed:
        def add_scope(key, day_keys):
            totals = sum_usage(daily[day] for day in day_keys)
            ids = rank_usage(totals)[:limit]
            keep = set(ids)
            scope = {"ids": ids, "by": fold(totals, keep)}
            if len(day_keys) > 1:
                scope["buckets"] = {day: fold(daily[day], keep) for day in day_keys}
            scopes[key] = scope
            for item in ids:
                if item not in scope_metadata:
                    scope_metadata[item] = metadata(item)

        for day, _ in dates:
            add_scope(day, [day])
        for key, length in (("3d", 3), ("14d", 14)):
            add_scope(key, [day for day, _ in dates[-length:]])

    highlights = []
    for length in (1, 7, 14):
        by, raw = {}, {}
        for day, _ in dates[-length:]:
            for item, seconds in daily[day].items():
                by[item] = by.get(item, 0) + seconds
            for app, seconds in raw_days[day].items():
                raw[app] = raw.get(app, 0) + seconds
        leader = min(by, key=lambda item: (-by[item], item)) if by else ""
        raw_leader = min(raw, key=lambda app: (-raw[app], app)) if raw else ""
        other = min((app for app in raw if not is_browser(app)), key=lambda app: (-raw[app], app), default="")
        info = metadata(leader) if leader else {"name": ""}
        highlights.append({
            "total": sum(day["sec"] for day in days[-length:]),
            "top": info["name"],
            "topDomain": info.get("domain", ""),
            "topSec": by.get(leader, 0),
            "browserSec": sum(seconds for app, seconds in raw.items() if is_browser(app)),
            "outside": other if raw_leader and is_browser(raw_leader) else "",
            "outsideSec": raw.get(other, 0),
        })

    print(json.dumps({
        "ok": True,
        "sec": days[-1]["sec"],
        "apps": [metadata(item) for item in top],
        **({
            "hourApps": [metadata(app) for app in hourly_top],
            "mixed": True,
            "usageScopes": scopes,
            "usageApps": scope_metadata,
        } if mixed else {}),
        "hidden": len(ranked) - len(top),
        "expanded": limit > 12,
        "days": days,
        "hours": hours,
        "highlights": highlights,
        **({"sites": sites} if sites is not None else {}),
    }))


if __name__ == "__main__":
    main()
