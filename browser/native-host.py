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


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as temp:
        temporary_path = Path(temp.name)
        try:
            json.dump(data, temp, separators=(",", ":"))
            temp.close()
            temporary_path.replace(path)
        finally:
            temporary_path.unlink(missing_ok=True)


def save_totals(message):
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
                len(hostname) <= 253
                and all(LABEL.fullmatch(label) for label in hostname.split("."))
                and type(ms) is int
                and 0 < ms <= 86_400_000
            ):
                clean[hostname] = ms
        totals[day] = dict(sorted(clean.items(), key=lambda item: -item[1])[:128])

    directory = xdg_dir("XDG_STATE_HOME", ".local/state") / "lat-dashboard/site-usage"
    atomic_json(directory / f"{profile}.json", totals)
    return True


def serve():
    header = sys.stdin.buffer.read(4)
    if len(header) != 4:
        return
    length, = struct.unpack("=I", header)
    if length > MAX_BYTES:
        return
    try:
        message = json.loads(sys.stdin.buffer.read(length))
        ok = save_totals(message)
    except (OSError, UnicodeError, ValueError):
        ok = False
    response = json.dumps({"ok": ok}).encode()
    sys.stdout.buffer.write(struct.pack("=I", len(response)) + response)
    sys.stdout.buffer.flush()


def install(browser_dir):
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
        "path": str(script),
        "type": "stdio",
        "allowed_origins": [f"chrome-extension://{extension_id}/"],
    })
    print(f"Installed site-time bridge in {target}")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--install":
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--install", nargs="?", type=Path, metavar="BRAVE_USER_DATA_DIR")
        install(parser.parse_args().install)
    else:
        serve()
