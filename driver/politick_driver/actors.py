"""Actors: things that turn a tick report into log entries.

Scripted and random actors are the test harness (kernel bugs and persona
bugs stay distinguishable — dsl-sketch.md §11 build order); the LLM actor
is the M4 payoff. All of them may only emit events or begin procedures —
exactly the powers the kernel grants external entries.
"""

from __future__ import annotations

import json
import logging
import random
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

from .kernel import Kernel, TickReport
from .llm import Llm, diff_grammar

log = logging.getLogger("politick_driver")


@dataclass(frozen=True)
class Event:
    name: str
    args: list

    def payload(self) -> dict:
        return {"name": self.name, "args": self.args}


@dataclass(frozen=True)
class Begin:
    procedure: str
    bill: dict

    def payload(self) -> dict:
        return {"procedure": self.procedure, "bill": self.bill}


Action = Event | Begin


class Actor(Protocol):
    name: str

    def act(self, tick: int, report: TickReport) -> list[Action]:
        """Decide on actions after observing tick `tick`; the driver
        schedules them for tick+1."""
        ...


@dataclass
class ScriptedActor:
    name: str
    script: dict[int, list[Action]]

    def act(self, tick: int, report: TickReport) -> list[Action]:
        return self.script.get(tick, [])


@dataclass
class RandomActor:
    """Seeded noise generator: emits candidate events at random ticks.
    Deterministic per seed, so driver-level runs are reproducible."""

    name: str
    seed: int
    events: list[Event]
    rate: float = 0.3

    def __post_init__(self):
        self._rng = random.Random(self.seed)

    def act(self, tick: int, report: TickReport) -> list[Action]:
        if self.events and self._rng.random() < self.rate:
            return [self._rng.choice(self.events)]
        return []


def summarize_world(report: TickReport) -> str:
    """Compact world-state view for the persona prompt: facts (including
    staged_diff = pending legislation and proc_instance = bills in
    passage) plus this tick's events."""
    lines = [f"tick: {report.tick}"]
    for schema, table in report.facts.items():
        if not table["rows"]:
            continue
        header = ",".join(table["fields"])
        rows = "; ".join(",".join(map(_terse, r)) for r in table["rows"])
        lines.append(f"{schema}({header}): {rows}")
    events = [e for e in report.events if not e["name"].startswith("tick.")]
    if events:
        lines.append("events: " + "; ".join(f"{e['name']}({', '.join(map(_terse, e['args']))})" for e in events))
    if report.commits:
        lines.append("verdicts: " + "; ".join(f"{c['diff']}={c['outcome']}" for c in report.commits))
    return "\n".join(lines)


def _terse(v) -> str:
    return json.dumps(v) if not isinstance(v, str) else v


INTENT_PROMPT = """You are playing {name}, a political actor in a simulated country.

{persona}

Current world state:
{world}

Decide your move this turn. Reply with exactly one of:
- PASS — if you take no action this turn.
- BILL: <one or two sentences describing the statute you want to enact
  and which facts/rules it should change>

Do not draft any JSON yet."""

COMPILE_PROMPT = """Compile the bill below into a politick diff object.

The world's schemas and current facts:
{world}

Bill intent:
{intent}

Rules for the diff object:
- "name" is a fresh snake_case identifier for the act; "by" is "{name}"; "via" is "{procedure}".
- "ops" holds the changes. Reference only schemas and fields that exist above (or that the diff itself adds).
- Rules react to events ("on") and may update facts or emit events.
Output only the JSON diff object."""

RETRY_PROMPT = """The kernel rejected that draft: {feedback}

Fix the diff and output only the corrected JSON diff object."""


@dataclass
class LlmActor:
    """Two-turn persona: free-text intent first, then a grammar-constrained
    compile, then the kernel-check retry loop (dsl-sketch.md §8.3)."""

    name: str
    persona: str
    llm: Llm
    kernel: Kernel
    log_path: Path
    procedure: str = "pass_statute"
    max_retries: int = 3
    bill_counter: int = field(default=0)

    def act(self, tick: int, report: TickReport) -> list[Action]:
        world = summarize_world(report)
        log.info("[%s] tick %d: deciding…", self.name, tick)
        # Intent is short prose; cap it so a rambling model can't stall
        # the tick. Persona variety keeps the client's default temperature.
        intent = self.llm.chat(
            self.persona,
            [{"role": "user", "content": INTENT_PROMPT.format(name=self.name, persona=self.persona, world=world)}],
            max_tokens=256,
        ).strip()
        if not intent.upper().startswith("BILL"):
            log.info("[%s] tick %d: passes", self.name, tick)
            return []
        log.info("[%s] tick %d: %s", self.name, tick, intent.splitlines()[0][:120])

        messages = [{"role": "user", "content": COMPILE_PROMPT.format(
            world=world, intent=intent, name=self.name, procedure=self.procedure)}]
        for attempt in range(1, self.max_retries + 1):
            # Compile wants precision, not creativity.
            draft_text = self.llm.chat(
                self.persona, messages, grammar=diff_grammar(), temperature=0.2
            )
            try:
                bill = json.loads(draft_text)
            except json.JSONDecodeError:
                # Impossible under the grammar; reachable with a FakeLlm.
                feedback = "output was not valid JSON"
            else:
                verdict = self.kernel.check(self.log_path, bill)
                if verdict.ok:
                    log.info("[%s] tick %d: drafted %s (attempt %d)",
                             self.name, tick, bill.get("name", "?"), attempt)
                    return [Begin(self.procedure, bill)]
                feedback = verdict.retry_feedback()
            log.info("[%s] tick %d: draft rejected (%s), attempt %d/%d",
                     self.name, tick, feedback, attempt, self.max_retries)
            messages.append({"role": "assistant", "content": draft_text})
            messages.append({"role": "user", "content": RETRY_PROMPT.format(feedback=feedback)})
        log.info("[%s] tick %d: abstains after %d failed drafts", self.name, tick, self.max_retries)
        return []  # abstain this tick; the world moves on
