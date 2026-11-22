#!/usr/bin/env python3
"""Browse and update Markdown files within the user's configured vault."""

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
from urllib.parse import unquote, urlsplit


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


IMAGE_TYPES = {".png", ".jpeg", ".jpg", ".webp", ".gif", ".bmp"}
ATTACHMENT_TYPES = IMAGE_TYPES | {".svg", ".pdf", ".mp3", ".ogg", ".wav", ".m4a", ".mp4", ".webm", ".mov", ".avif"}
MAX_INLINE_BYTES = 12 * 1024 * 1024
MAX_INLINE_IMAGES = 6

TOKEN = re.compile(
    r"(?P<code>(?P<ticks>`+).*?(?P=ticks))"
    r"|(?<!\\)(?P<wiki>!?\[\[(?P<target>[^\]\n]+)\]\])"
    r"|(?<!\\)(?P<link>!?\[(?P<label>[^\]\n]*)\]\("
    r"(?P<url><[^>\n]+>|(?:[^\s()]+|\([^()\n]*\))+)"
    r"(?:[ \t]+(?:\"[^\"]*\"|'[^']*'))?\))"
)
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")


def attachment(path, root):
    suffix = path.suffix.lower()
    if suffix not in ATTACHMENT_TYPES or not path.is_file():
        raise ValueError("This attachment is missing or unsupported.")
    return {
        "kind": "attachment", "title": path.name, "relative": path.relative_to(root).as_posix(),
        "path": str(path), "image": suffix in IMAGE_TYPES and path.stat().st_size <= MAX_INLINE_BYTES,
        "modified": int(path.stat().st_mtime),
    }


def create_item(folder, root, name, kind):
    name = name.strip()
    if (
        not name or name.startswith(".") or "/" in name or "\\" in name
        or any(ord(character) < 32 for character in name)
    ):
        raise ValueError("Use a name without slashes or a leading dot.")
    if kind == "note" and not name.lower().endswith(".md"):
        name += ".md"
    path = folder / name
    try:
        if kind == "folder":
            path.mkdir()
        else:
            with path.open("xb"):
                pass
    except FileExistsError as error:
        raise ValueError("A file or folder with this name already exists.") from error
    return {"ok": True, "relative": path.relative_to(root).as_posix()}


class VaultLinks:
    def __init__(self, root, note):
        self.root = root
        self.note = note
        self.index = None

    def describe(self, path):
        try:
            resolved = path.resolve()
            if not resolved.is_relative_to(self.root):
                return None
            if resolved.suffix.lower() == ".md" and resolved.is_file():
                return {"kind": "note", "title": resolved.stem, "relative": resolved.relative_to(self.root).as_posix()}
            return attachment(resolved, self.root)
        except (OSError, ValueError, RuntimeError):
            return None

    def link(self, target, wiki):
        target = target.strip().removeprefix("<").removesuffix(">")
        if not wiki:
            try:
                url = urlsplit(target)
            except ValueError:
                return None
            if url.scheme in {"http", "https"} and url.netloc:
                return {"kind": "url", "url": target, "title": url.netloc}
            if url.scheme or url.netloc:
                return None
            target = unquote(url.path)
        else:
            target = target.split("#", 1)[0]
        if not target or Path(target).is_absolute():
            return None

        for base in (self.note.parent, self.root):
            for name in (target, target + ".md"):
                result = self.describe(base / name)
                if result is not None:
                    return result

        # Obsidian also accepts short names that are unique elsewhere in the vault.
        if ".." in Path(target).parts:
            return None
        if self.index is None:
            self.index = {}
            for directory, folders, files in os.walk(self.root):
                folders[:] = sorted(name for name in folders if not name.startswith("."))
                for name in files:
                    path = Path(directory) / name
                    if not name.startswith(".") and path.suffix.lower() in ATTACHMENT_TYPES | {".md"}:
                        self.index.setdefault(name.casefold(), []).append(path)
        candidates = self.index.get(Path(target).name.casefold(), []) + self.index.get(
            (Path(target).name + ".md").casefold(), []
        )
        for name in (target, target + ".md"):
            suffix = "/" + name.casefold()
            matching = [path for path in candidates if ("/" + path.relative_to(self.root).as_posix().casefold()).endswith(suffix)]
            if len(matching) == 1:
                return self.describe(matching[0])
        return None


def preview_blocks(root, note, text):
    lines = text.splitlines(keepends=True)
    if lines and lines[0].strip() == "---":
        for index, line in enumerate(lines[1:], 1):
            if line.strip() in {"---", "..."}:
                lines = lines[index + 1:]
                break
    resolver = VaultLinks(root, note)
    blocks, links, pending = [], {}, []
    fence = None
    inline_count = 0

    def flush():
        markdown = "".join(pending)
        if markdown.strip():
            blocks.append({"kind": "markdown", "text": markdown})
        pending.clear()

    for line in lines:
        marker = FENCE.match(line)
        if fence is not None:
            pending.append(line)
            if marker and marker.group(1)[0] == fence[0] and len(marker.group(1)) >= len(fence):
                fence = None
            continue
        if marker:
            fence = marker.group(1)
            pending.append(line)
            continue

        cursor = 0
        for match in TOKEN.finditer(line):
            pending.append(line[cursor:match.start()])
            cursor = match.end()
            if match.group("code") is not None:
                pending.append(match.group())
                continue

            wiki = match.group("wiki") is not None
            embed = match.group().startswith("!")
            if wiki:
                target, _, alias = match.group("target").partition("|")
                label = alias or target
                if embed and re.fullmatch(r"\d+(?:x\d+)?", alias):
                    label = target
            else:
                target = match.group("url")
                label = match.group("label")

            result = resolver.link(target, wiki)
            if result is None:
                pending.append(label or match.group())
                continue
            if label:
                result["title"] = label
            if embed:
                flush()
                if result.get("image"):
                    inline_count += 1
                    result["image"] = inline_count <= MAX_INLINE_IMAGES
                blocks.append(result)
            else:
                pending.append(label or result["title"])
                key = result.get("relative") or result["url"]
                links.setdefault(key, result)
        pending.append(line[cursor:])
    flush()
    return {"ok": True, "blocks": blocks, "links": list(links.values())}


def folder_entries(path):
    entries = []
    for entry in path.iterdir():
        if entry.name.startswith(".") or entry.is_symlink():
            continue
        if entry.is_dir():
            kind = "folder"
        elif entry.is_file() and entry.suffix.lower() in ATTACHMENT_TYPES | {".md"}:
            kind = "note" if entry.suffix.lower() == ".md" else "attachment"
        else:
            continue
        entries.append({"name": entry.name, "kind": kind})
    order = {"folder": 0, "note": 1, "attachment": 2}
    return sorted(entries, key=lambda entry: (order[entry["kind"]], entry["name"].casefold(), entry["name"]))


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
    return {"ok": True, "revision": revision(content), "modified": int(path.stat().st_mtime)}


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
        return {
            "ok": True, "text": raw.decode("utf-8-sig").replace("\r\n", "\n"),
            "revision": revision(raw), "modified": int(path.stat().st_mtime),
        }
    if operation == "preview":
        raw = note_bytes(Path(extra[0]) if extra else path)
        return preview_blocks(root, path, raw.decode("utf-8-sig"))
    if operation == "attachment":
        return {"ok": True, "attachment": attachment(path, root)}
    if operation in {"new-note", "new-folder"}:
        return create_item(path, root, extra[0], "note" if operation == "new-note" else "folder")
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
