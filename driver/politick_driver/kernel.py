"""Subprocess wrapper around the politick kernel binary.

One kernel invocation per tick, refolding the log from scratch each time
(O(ticks²) total, accepted — same spirit as the kernel's naive derive
recompute). The kernel is the only holder of world state; the driver sees
it exclusively through --json tick reports and check verdicts.
"""

from __future__ import annotations

import json
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class TickReport:
    tick: int
    digest: str
    events: list[dict]
    commits: list[dict]
    facts: dict[str, dict]
    rules: list[dict]

    def rows(self, schema: str) -> list[list[Any]]:
        table = self.facts.get(schema)
        return table["rows"] if table else []


@dataclass(frozen=True)
class Verdict:
    ok: bool
    reason: str | None = None
    deps: list[str] = field(default_factory=list)
    diag: dict | None = None
    min_staged_ticks: int | None = None
    layers: list[str] = field(default_factory=list)

    def retry_feedback(self) -> str:
        """Human-readable rejection summary for the LLM retry loop."""
        parts = [f"reason: {self.reason}"]
        if self.deps:
            parts.append(f"offending terms: {', '.join(self.deps)}")
        if self.diag:
            d = self.diag
            detail = d.get("code", "")
            if d.get("symbol"):
                detail += f" on '{d['symbol']}'"
            if d.get("field"):
                detail += f", field '{d['field']}'"
            if d.get("expected") is not None and d.get("got") is not None:
                detail += f" (expected {d['expected']} value(s), got {d['got']})"
            parts.append(f"detail: {detail}")
        return "; ".join(parts)


class KernelError(RuntimeError):
    pass


class Kernel:
    def __init__(self, binary: Path, seed: int = 42):
        self.binary = Path(binary)
        self.seed = seed

    def run(self, log_path: Path, ticks: int) -> list[TickReport]:
        """Fold the log and run `ticks` ticks; one report per tick."""
        proc = subprocess.run(
            [str(self.binary), "--log", str(log_path), "--ticks", str(ticks), "--seed", str(self.seed), "--json"],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        if proc.returncode != 0:
            raise KernelError(f"kernel run failed: {proc.stderr.strip() or proc.stdout.strip()}")
        reports = []
        for line in proc.stdout.splitlines():
            if not line:
                continue
            obj = json.loads(line)
            reports.append(
                TickReport(obj["tick"], obj["digest"], obj["events"], obj["commits"], obj["facts"], obj["rules"])
            )
        return reports

    def check(self, log_path: Path, diff: dict) -> Verdict:
        """Static validation of a draft diff object against the log's world."""
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
            json.dump(diff, f)
            draft = Path(f.name)
        try:
            proc = subprocess.run(
                [str(self.binary), "check", "--log", str(log_path), "--diff", str(draft), "--seed", str(self.seed)],
                capture_output=True,
                text=True,
                encoding="utf-8",
            )
        finally:
            draft.unlink()
        # exit 0 = ok, 1 = rejected/undecodable (verdict on stdout either way)
        if proc.returncode not in (0, 1) or not proc.stdout.strip():
            raise KernelError(f"kernel check failed: {proc.stderr.strip() or proc.stdout.strip()}")
        obj = json.loads(proc.stdout.strip().splitlines()[-1])
        return Verdict(
            ok=obj["ok"],
            reason=obj.get("reason"),
            deps=obj.get("deps", []),
            diag=obj.get("diag"),
            min_staged_ticks=obj.get("min_staged_ticks"),
            layers=obj.get("layers", []),
        )

    def digest_chain(self, log_path: Path, ticks: int) -> str:
        """Replay without --json and return the final run digest — the
        exit-criterion probe (byte-identical replay sans driver)."""
        proc = subprocess.run(
            [str(self.binary), "--log", str(log_path), "--ticks", str(ticks), "--seed", str(self.seed)],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        if proc.returncode != 0:
            raise KernelError(f"kernel replay failed: {proc.stderr.strip()}")
        last = proc.stdout.strip().splitlines()[-1]
        assert last.startswith("run digest ")
        return last.removeprefix("run digest ")
