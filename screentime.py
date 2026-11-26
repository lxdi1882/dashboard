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
BROWSERS = {
    "brave": ("Brave", re.compile(r"(?:^|[.])brave(?:$|[-.])")),
    "vivaldi": ("Vivaldi", re.compile(r"(?:^|[.])vivaldi(?:$|[-.])")),
}
SITE_PREFIX = "site:"


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
    """Read the browser exports separately and share metadata for matching sites."""
    browser_days = {}
    browser_hours = {}
    icon_paths = {}
    directory = Path(directory)
    loaded = False
    for browser in BROWSERS:
        source = directory if browser == "brave" else directory / browser
        days = {day: {} for day, _ in dates}
        for path in sorted(source.glob("*.json")):
            try:
                profile = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if not isinstance(profile, dict):
                continue
            loaded = True
            browser_days[browser] = days
            for day, by_domain in profile.items():
                if day not in days or not isinstance(by_domain, dict):
                    continue
                for hostname, duration in by_domain.items():
                    if type(duration) is not int or duration <= 0 or not re.fullmatch(r"[a-z0-9.-]{1,253}", hostname):
                        continue
                    domain = re.sub(r"^www[0-9]*\.(?=.+\.)", "", hostname)
                    days[day][domain] = days[day].get(domain, 0) + duration
                    name = hashlib.sha256(hostname.encode("ascii")).hexdigest() + ".png"
                    icon_paths.setdefault(domain, set()).add(source / "icons" / path.stem / name)
            hourly = profile.get("_hours")
            if not isinstance(hourly, dict):
                continue
            for day, by_domain in hourly.items():
                if day not in days or not isinstance(by_domain, dict):
                    continue
                for hostname, buckets in by_domain.items():
                    if not re.fullmatch(r"[a-z0-9.-]{1,253}", hostname) or not isinstance(buckets, list):
                        continue
                    domain = re.sub(r"^www[0-9]*\.(?=.+\.)", "", hostname)
                    for hour, duration in enumerate(buckets[:24]):
                        if type(duration) is int and 0 < duration <= 86_400_000:
                            sites = browser_hours.setdefault(browser, {}).setdefault((day, hour), {})
                            sites[domain] = sites.get(domain, 0) + duration
    if not loaded:
        return None, {}, {}, None

    days = {day: sum_usage(by_day[day] for by_day in browser_days.values()) for day, _ in dates}

    def trend_for(domain):
        return {
            "seconds": [days[day].get(domain, 0) // 1000 for day, _ in dates],
            "icon": next((str(path) for path in sorted(icon_paths.get(domain, ())) if path.is_file()), ""),
            "name": site_label(domain),
        }

    return {
        "calendar": [{"date": day, "recorded": bool(days[day])} for day, _ in dates],
        "trends": {},
    }, browser_days, browser_hours, trend_for


def attribute_sites(apps, browser_usage, bucket, *, daily=False):
    """Subdivide each browser's own app time and combine matching site entries."""
    result = apps
    for browser, (_, pattern) in BROWSERS.items():
        if browser not in browser_usage or bucket not in browser_usage[browser]:
            continue
        site_ms = browser_usage[browser][bucket]
        browser_apps = [app for app in apps if pattern.search(app.lower())]
        budget = sum(apps[app] for app in browser_apps)
        total_ms = sum(site_ms.values())
        credited = min(budget, total_ms // 1000)
        # Keep the legacy Brave remainder label once an export exists.
        if budget <= 0 or (credited <= 0 and not (daily and browser == "brave")):
            continue
        if result is apps:
            result = apps.copy()
        for app in browser_apps:
            del result[app]
        if credited > 0:
            # Cumulative rounding keeps the split equal to the credited budget.
            cumulative_ms = 0
            allocated = 0
            for domain, duration in sorted(site_ms.items()):
                cumulative_ms += duration
                target = cumulative_ms * credited // total_ms
                if target > allocated:
                    item = SITE_PREFIX + domain
                    result[item] = result.get(item, 0) + target - allocated
                allocated = target
        if budget > credited:
            result[f"browser:{browser}-other"] = budget - credited
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

    sites, site_days, site_hours, trend_for = load_sites(sys.argv[3], dates) if len(sys.argv) > 3 else (None, {}, {}, None)

    def in_seconds(by):
        return {app: sec for app, duration in by.items() if (sec := int(duration / div)) > 0}

    raw_days = {day: in_seconds(accs[day].apps) if day in accs else {} for day, _ in dates}
    daily = {day: attribute_sites(by, site_days, day, daily=True)
             for day, by in raw_days.items()}
    mixed = any(daily[day] is not by for day, by in raw_days.items())
    ranked = rank_usage(sum_usage(daily.values()))
    raw_ranked = rank_usage(sum_usage(raw_days.values())) if mixed else ranked
    limit = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 12
    top = ranked[:limit]
    top_set = set(top)

    def fold(by, keep):
        out = {}
        for item, seconds in by.items():
            key = item if item in keep else "_other"
            out[key] = out.get(key, 0) + seconds
        return out

    days = []
    hours = []
    hourly_visible = {}
    hourly_mixed = False
    for d, lab in dates:
        a = accs.get(d)
        day = {"d": d, "label": lab, "sec": int(a.total / div) if a else 0, "by": fold(daily[d], top_set)}
        if a is not None and a.hour_apps:
            day_hours = {}
            for h in range(24):
                raw_hour = in_seconds(a.hour_apps.get(h, {}))
                attributed = attribute_sites(raw_hour, site_hours, (d, h))
                hourly_mixed = hourly_mixed or attributed is not raw_hour
                keep = set(rank_usage(attributed)[:limit])
                by = fold(attributed, keep)
                for item in keep:
                    hourly_visible[item] = hourly_visible.get(item, 0) + by[item]
                if d == dates[-1][0]:
                    hours.append({"sec": sum(by.values()), "by": by})
                elif by:
                    day_hours[f"h{h}"] = by
            if d != dates[-1][0]:
                day["hours"] = day_hours
        days.append(day)

    hourly_top = rank_usage(hourly_visible)
    icons = desktop_icons() if top or hourly_top else {}
    remainders = {}
    for browser, (label, pattern) in BROWSERS.items():
        app = next((app for app in raw_ranked if pattern.search(app.lower())), "")
        remainders[f"browser:{browser}-other"] = (f"Other {label} time", icons.get(app.lower(), app))

    def metadata(item):
        if sites is not None and item.startswith(SITE_PREFIX):
            domain = item[len(SITE_PREFIX):]
            if domain not in sites["trends"]:
                sites["trends"][domain] = trend_for(domain)
            trend = sites["trends"][domain]
            return {"id": item, "name": trend["name"], "domain": domain, "icon": trend["icon"]}
        if item in remainders:
            name, icon = remainders[item]
            return {"id": item, "name": name, "icon": icon}
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
        period = days[-length:]
        history = days[-max(7, length):]
        by = sum_usage(daily[day["d"]] for day in period)
        highlights.append({
            "total": sum(day["sec"] for day in period),
            "items": [
                {
                    **metadata(item),
                    "sec": by[item],
                    "history": [
                        {"date": day["d"], "sec": daily[day["d"]].get(item, 0), "recorded": day["sec"] > 0}
                        for day in history
                    ],
                }
                for item in rank_usage(by)[:3]
            ],
        })

    print(json.dumps({
        "ok": True,
        "sec": days[-1]["sec"],
        "apps": [metadata(item) for item in top],
        "hourApps": [metadata(app) for app in hourly_top],
        "hourlyMixed": hourly_mixed,
        **({
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
