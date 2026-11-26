#!/usr/bin/env python3
"""Receive local aggregate browser timing and register the native messaging host."""

import argparse
import base64
from datetime import date, timedelta
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import sys
from tempfile import NamedTemporaryFile

HOST = "io.github.lxdi1882.dashboard_sites"
PROFILE = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")
MAX_BYTES = 1024 * 1024


def xdg_dir(variable, fallback):
    return Path(os.environ.get(variable) or Path.home() / fallback)


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with NamedTemporaryFile(dir=path.parent, delete=False) as temp:
        temporary_path = Path(temp.name)
        try:
            temp.write(data)
            temp.close()
            temporary_path.replace(path)
        finally:
            temporary_path.unlink(missing_ok=True)


def atomic_json(path, data):
    atomic_write(path, json.dumps(data, separators=(",", ":")).encode("utf-8"))


def valid_domain(domain):
    return isinstance(domain, str) and len(domain) <= 253 and all(
        LABEL.fullmatch(label) for label in domain.split(".")
    )


def save_icon(directory, icon):
    if not isinstance(icon, dict):
        return
    domain, encoded = icon.get("domain"), icon.get("png")
    if not valid_domain(domain) or not isinstance(encoded, str) or len(encoded) > 44_000:
        return
    try:
        png = base64.b64decode(encoded, validate=True)
    except ValueError:
        return
    if len(png) < 33 or png[:8] != b"\x89PNG\r\n\x1a\n" or png[12:16] != b"IHDR":
        return
    width, height = struct.unpack(">II", png[16:24])
    if not (1 <= width <= 64 and 1 <= height <= 64):
        return
    name = hashlib.sha256(domain.encode("ascii")).hexdigest() + ".png"
    atomic_write(directory / name, png)
    files = sorted(directory.glob("*.png"), key=lambda path: path.stat().st_mtime, reverse=True)
    for stale in files[128:]:
        stale.unlink(missing_ok=True)


def save_totals(message, browser):
    if not isinstance(message, dict):
        return False
    profile, days = message.get("profile"), message.get("days")
    if not isinstance(profile, str) or not PROFILE.fullmatch(profile) or not isinstance(days, dict):
        return False

    today = date.today()
    valid_dates = {(today - timedelta(days=n)).isoformat() for n in range(14)}
    totals = {}
    for day, sites in days.items():
        if day not in valid_dates or not isinstance(sites, dict):
            continue
        clean = {}
        for hostname, ms in sites.items():
            if (
                valid_domain(hostname)
                and type(ms) is int
                and 0 < ms <= 86_400_000
            ):
                clean[hostname] = ms
        totals[day] = dict(sorted(clean.items(), key=lambda item: -item[1])[:128])

    hours = message.get("hours")
    if isinstance(hours, dict):
        hourly = {}
        for day, sites in hours.items():
            if day not in totals or not isinstance(sites, dict):
                continue
            hourly[day] = {
                hostname: buckets
                for hostname, buckets in sites.items()
                if hostname in totals[day]
                and isinstance(buckets, list)
                and len(buckets) == 24
                and all(type(ms) is int and 0 <= ms <= 86_400_000 for ms in buckets)
                and 0 < sum(buckets) <= totals[day][hostname]
            }
        totals["_hours"] = hourly

    directory = xdg_dir("XDG_STATE_HOME", ".local/state") / "lat-dashboard/site-usage"
    if browser == "vivaldi":
        directory /= browser
    atomic_json(directory / f"{profile}.json", totals)
    icons = directory / "icons" / profile
    if message.get("clearIcons") is True:
        for icon in icons.glob("*.png"):
            icon.unlink(missing_ok=True)
    elif "icon" in message:
        try:
            save_icon(icons, message["icon"])
        except OSError:
            pass
    return True


def serve(browser):
    header = sys.stdin.buffer.read(4)
    if len(header) != 4:
        return
    length, = struct.unpack("=I", header)
    if length > MAX_BYTES:
        return
    try:
        message = json.loads(sys.stdin.buffer.read(length))
        ok = save_totals(message, browser)
    except (OSError, UnicodeError, ValueError):
        ok = False
    response = json.dumps({"ok": ok}).encode()
    sys.stdout.buffer.write(struct.pack("=I", len(response)) + response)
    sys.stdout.buffer.flush()


def install(browser_dir, browser):
    if browser == "vivaldi":
        if browser_dir is None:
            browser_dir = xdg_dir("XDG_CONFIG_HOME", ".config") / "vivaldi"
        launcher = Path(__file__).resolve().with_name("vivaldi-host")
    else:
        launcher = Path(__file__).resolve()
    if browser_dir is None:
        vendor = xdg_dir("XDG_CONFIG_HOME", ".config") / "BraveSoftware"
        candidates = [path for path in vendor.glob("Brave-*") if path.is_dir()]
        if len(candidates) != 1:
            sys.exit("Pass the Brave user data directory after --install. It is the parent of Profile Path in brave://version.")
        browser_dir = candidates[0]

    script = Path(__file__).resolve()
    manifest = json.loads(script.with_name("manifest.json").read_text(encoding="utf-8"))
    digest = hashlib.sha256(base64.b64decode(manifest["key"])).hexdigest()[:32]
    extension_id = digest.translate(str.maketrans("0123456789abcdef", "abcdefghijklmnop"))
    target = browser_dir.expanduser().resolve() / "NativeMessagingHosts" / f"{HOST}.json"
    atomic_json(target, {
        "name": HOST,
        "description": "Local Noctalia dashboard site usage",
        "path": str(launcher),
        "type": "stdio",
        "allowed_origins": [f"chrome-extension://{extension_id}/"],
    })
    print(f"Installed site-time bridge in {target}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", nargs="?", type=Path, const=True, metavar="USER_DATA_DIR")
    parser.add_argument("--browser", choices=("brave", "vivaldi"), default="brave")
    # Chromium supplies the caller origin as an argument when launching the host.
    if "--install" in sys.argv[1:]:
        args = parser.parse_args()
        install(None if args.install is True else args.install, args.browser)
    else:
        args, _ = parser.parse_known_args()
        serve(args.browser)
