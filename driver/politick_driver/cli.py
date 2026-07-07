"""Driver loop: invoke kernel → read tick report → actors decide → append
entries for the next tick. One kernel invocation per tick, refolding the
log each time; the log is the only shared state.

    politick-driver --log run.ndjson --ticks 20 --genesis worlds/legislature.json \
        [--kernel PATH] [--llm-url http://127.0.0.1:8080] [--persona baron] [--seed 42]

Without --llm-url the run is kernel-only (useful for replay checks).
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

from . import log as logmod
from .actors import Actor, Begin, LlmActor
from .kernel import Kernel, TickReport
from .llm import LlamaServer

PERSONA_DIR = Path(__file__).parent / "personas"


def default_kernel() -> Path:
    # repo layout: driver/politick_driver/cli.py → ../../zig-out/bin/politick
    return Path(__file__).resolve().parents[2] / "zig-out" / "bin" / "politick"


def drive(
    kernel: Kernel,
    log_path: Path,
    actors: list[Actor],
    ticks: int,
    on_tick=None,
) -> list[TickReport]:
    """Run `ticks` ticks, letting actors append entries between them.
    Returns the final run's reports (ticks 1..ticks)."""
    reports: list[TickReport] = []
    for t in range(1, ticks + 1):
        reports = kernel.run(log_path, ticks=t)
        report = reports[-1]
        if on_tick:
            on_tick(report)
        if t == ticks:
            break
        entries = logmod.read_log(log_path)
        seq = logmod.next_seq(entries)
        new_entries = []
        for actor in actors:
            for action in actor.act(t, report):
                kind = "begin" if isinstance(action, Begin) else "event"
                new_entries.append(logmod.Entry(tick=t + 1, seq=seq, kind=kind, payload=action.payload()))
                seq += 1
        logmod.append_entries(log_path, new_entries)
    return reports


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="politick-driver")
    p.add_argument("--log", type=Path, default=Path("run.ndjson"))
    p.add_argument("--ticks", type=int, default=20)
    p.add_argument("--genesis", type=Path, help="genesis ops JSON (used when creating a fresh log)")
    p.add_argument("--kernel", type=Path, default=default_kernel())
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--llm-url", help="llama-server base URL; omit for a kernel-only run")
    p.add_argument("--llm-seed", type=int, help="sampler seed for reproducible drafts")
    p.add_argument("--temperature", type=float, default=0.7)
    p.add_argument("--persona", default="baron", help="persona file name under personas/ (without .md)")
    p.add_argument("--actor-name", default=None, help="actor id used as bill provenance (default: persona name)")
    p.add_argument("--quiet", action="store_true", help="suppress per-tick progress on stderr")
    args = p.parse_args(argv)

    # Progress goes to stderr so stdout stays parseable (commits + digest).
    logging.basicConfig(
        level=logging.WARNING if args.quiet else logging.INFO,
        format="%(message)s",
        stream=sys.stderr,
    )

    if not args.kernel.exists():
        print(f"kernel binary not found: {args.kernel} (run `zig build` first)", file=sys.stderr)
        return 2

    if not args.log.exists():
        genesis = json.loads(args.genesis.read_text()) if args.genesis else None
        logmod.create_log(args.log, genesis)
    kernel = Kernel(args.kernel, seed=args.seed)

    actors: list[Actor] = []
    if args.llm_url:
        persona_file = PERSONA_DIR / f"{args.persona}.md"
        actors.append(
            LlmActor(
                name=args.actor_name or args.persona,
                persona=persona_file.read_text(),
                llm=LlamaServer(args.llm_url, seed=args.llm_seed, temperature=args.temperature),
                kernel=kernel,
                log_path=args.log,
            )
        )

    def on_tick(report: TickReport) -> None:
        for c in report.commits:
            print(f"tick {report.tick}: {c['diff']} {c['outcome']}"
                  + (f" ({c.get('reason')})" if c["outcome"] == "rejected" else ""))

    reports = drive(kernel, args.log, actors, args.ticks, on_tick=on_tick)
    print(f"run digest {reports[-1].digest}")
    # Exit-criterion probe: the kernel alone must reproduce this digest.
    replay = kernel.digest_chain(args.log, args.ticks)
    if replay != reports[-1].digest:
        print("REPLAY MISMATCH: kernel-only replay diverged from the driven run", file=sys.stderr)
        return 1
    print("replay ok (kernel-only digest matches)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
