"""NDJSON log I/O matching src/log.zig byte-for-byte.

Envelope field order is tick, seq, kind, payload; entries are single
lines with no spaces (separators=(",", ":")), matching log.entryLine's
hand formatting so a driver-written log replays identically.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

FORMAT_VERSION = 1
HEADER = '{"format":1}'


@dataclass(frozen=True)
class Entry:
    tick: int
    seq: int
    kind: str  # "diff" | "event" | "begin"
    payload: Any


def dumps_entry(entry: Entry) -> str:
    body = {
        "tick": entry.tick,
        "seq": entry.seq,
        "kind": entry.kind,
        "payload": entry.payload,
    }
    return json.dumps(body, separators=(",", ":"))


def create_log(path: Path, genesis_ops: list[dict] | None = None) -> None:
    """Write a fresh log: header plus an optional tick-0 genesis diff."""
    lines = [HEADER]
    if genesis_ops is not None:
        lines.append(dumps_entry(Entry(tick=0, seq=1, kind="diff", payload=genesis_ops)))
    path.write_text("\n".join(lines) + "\n")


def read_log(path: Path) -> list[Entry]:
    lines = [ln for ln in path.read_text().splitlines() if ln]
    if not lines:
        raise ValueError(f"{path}: empty log (missing header)")
    header = json.loads(lines[0])
    if header.get("format") != FORMAT_VERSION:
        raise ValueError(f"{path}: unsupported log format {header!r}")
    entries = []
    for ln in lines[1:]:
        obj = json.loads(ln)
        entries.append(Entry(obj["tick"], obj["seq"], obj["kind"], obj["payload"]))
    return entries


def next_seq(entries: list[Entry]) -> int:
    return max((e.seq for e in entries), default=0) + 1


def append_entries(path: Path, entries: list[Entry]) -> None:
    if not entries:
        return
    with path.open("a") as f:
        for e in entries:
            f.write(dumps_entry(e) + "\n")
