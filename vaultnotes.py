#!/usr/bin/env python3
"""Browse and update Markdown files within the user's configured vault."""

import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


MAX_NOTE_BYTES = 256 * 1024
PAGE_SIZE = 48


def within_vault(root, relative):
    request = Path(relative)
    if request.is_absolute() or ".." in request.parts:
        raise ValueError("That path is outside the vault.")
    path = (root / request).resolve()
    if not path.is_relative_to(root):
        raise ValueError("That path is outside the vault.")
    return path


def folder_entries(path):
    entries = []
    for entry in path.iterdir():
        if entry.name.startswith(".") or entry.is_symlink():
            continue
        kind = "folder" if entry.is_dir() else "note"
        if kind == "note" and (entry.suffix.lower() != ".md" or not entry.is_file()):
            continue
        entries.append({"name": entry.name, "kind": kind})
    return sorted(entries, key=lambda entry: (entry["kind"], entry["name"].casefold(), entry["name"]))


def note_bytes(path):
    if path.suffix.lower() != ".md":
        raise ValueError("Only Markdown notes can be edited.")
    if not path.is_file():
        raise ValueError("The selected Markdown file is unavailable.")
    with path.open("rb") as source:
        raw = source.read(MAX_NOTE_BYTES + 1)
    if len(raw) > MAX_NOTE_BYTES:
        raise ValueError("This note is too large for the dashboard editor.")
    return raw


def revision(raw):
    return hashlib.sha256(raw).hexdigest()


def save(path, expected, draft_path):
    raw = note_bytes(path)
    if revision(raw) != expected:
        return {"ok": False, "conflict": True}
    with draft_path.open("rb") as source:
        draft = source.read(MAX_NOTE_BYTES + 1)
    if len(draft) > MAX_NOTE_BYTES:
        raise ValueError("This draft is too large for the dashboard editor.")
    text = draft.decode("utf-8").replace("\r\n", "\n")
    if b"\r\n" in raw and b"\n" not in raw.replace(b"\r\n", b""):
        text = text.replace("\n", "\r\n")
    encoding = "utf-8-sig" if raw.startswith(b"\xef\xbb\xbf") else "utf-8"
    content = text.encode(encoding)
    fd, temporary_name = tempfile.mkstemp(prefix=".dashboard-note-", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "wb") as target:
            target.write(content)
            os.fchmod(target.fileno(), stat.S_IMODE(path.stat().st_mode))
        if revision(note_bytes(path)) != expected:
            return {"ok": False, "conflict": True}
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    return {"ok": True, "revision": revision(content)}


def command(args):
    operation, vault, relative, *extra = args
    root = Path(vault).resolve()
    if not root.is_dir():
        raise ValueError("Set your Obsidian vault folder in the Dashboard settings.")
    path = within_vault(root, relative)
    if operation == "list":
        offset = max(0, int(extra[0])) * PAGE_SIZE if extra else 0
        entries = folder_entries(path)
        return {"ok": True, "entries": entries[offset:offset + PAGE_SIZE], "more": offset + PAGE_SIZE < len(entries)}
    if operation == "read":
        raw = note_bytes(path)
        return {"ok": True, "text": raw.decode("utf-8-sig").replace("\r\n", "\n"), "revision": revision(raw)}
    if operation == "save":
        expected, draft_path = extra
        return save(path, expected, Path(draft_path))
    raise ValueError("Unknown vault operation.")


def main():
    try:
        result = command(sys.argv[1:])
    except UnicodeError:
        result = {"ok": False, "error": "This note is not valid UTF-8."}
    except ValueError as error:
        result = {"ok": False, "error": str(error)}
    except OSError:
        result = {"ok": False, "error": "The vault item could not be accessed."}
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
