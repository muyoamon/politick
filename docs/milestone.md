# Milestones

Tracks the vertical slices from `dsl-sketch.md` §11 as concrete milestones
with exit criteria. A milestone is done when its exit criteria hold on a
fresh clone with `zig build test` passing.

## M0 — Kernel skeleton ✅ (2026-07-05)

Scaffolding and the determinism substrate: everything later work is
tested against.

- Zig project (`zig build`, `zig build run`, `zig build test`), library
  module + CLI split.
- Symbol interner (`intern.zig`) — insertion-ordered ids; canonical symbol
  order = integer order.
- `Value` tagged union (`value.zig`) with total order and canonical byte
  encoding; NaN rejected at validation.
- Canonical state hasher (`hash.zig`) — domain-separated SHA-256, the test
  oracle for all replay tests.
- NDJSON log (`log.zig`) — versioned header, deterministic hand-formatted
  envelopes (`tick`, `seq`, `kind`, `payload`); `seq` doubles as provenance
  timestamp.
- Tick loop (`tick.zig`) — READ → ACT → APPLY → COMMIT as stubs, arena per
  tick, seeded PRNG, chained per-tick digest.
- CLI (`main.zig`) — creates/validates the log, runs N ticks, prints the
  digest chain; malformed logs fail loudly.

**Exit criteria (met):** two runs with the same log and seed produce
byte-identical output; corrupt logs are rejected; 100-tick two-world
determinism test passes.

## M1 — Facts + interpreted rules (slice 1) ✅ (2026-07-06)

The poll-tax world runs end to end. The DSL exists as IR; genesis diffs
apply unconditionally (meta validation is M2).

- `ir.zig`: typed IR for fact schemas, events, and rules (`on` / `when` /
  `do` with a small expression tree), JSON (de)serialization. Kernel vs.
  user event namespaces separated from day one.
- `store.zig`: fact store keyed by schema symbol; rows schema-checked at
  insert; reads only during READ/ACT, updates queue during ACT and flush in
  APPLY (the store enforces phase discipline).
- Expression interpreter for rule bodies: `when` predicates,
  `emit`/`update` actions, bounded comprehensions over fact sets, fuel
  limit. A failing rule drops all its queued actions atomically and emits a
  kernel event (§10).
- Derives as hardcoded Zig functions behind the pure-function interface
  (Tier-0 math stays kernel-provided for now).
- Rules-by-event-type index — the only index in v1.
- Phase 2 conflict resolution: priority, then provenance `seq`.
- State hash covers the fact store (canonical order); chain digest becomes
  meaningful.
- Toy scenario seeded **as IR in the log**, not code: schemas, initial
  facts, and the `collect_poll_tax` rule (§2.3).

**Exit criteria (met):** the poll-tax world (`src/testdata/poll_tax.ndjson`)
runs 100 ticks with approval drifting down as taxes fire; the golden digest
is checked in (`src/golden_test.zig`) and reproduced on a fresh build and
via the CLI; a rule that errors leaves no partial writes and raises
`rule_failed` the same tick.

## M2 — Diffs + meta (slice 2) ✅ (2026-07-06)

The commit check — the heart of the system.

- Diff IR: `add`/`remove`/`set` over rules, schemas, params; provenance.
- Staged diffs as facts (rules can react to pending legislation).
- COMMIT phase: validation (type + reference closure check, §9) then meta
  rule check; **apply is total** — the §9 cascade (drop orphaned facts,
  `facts_dropped` events, schema change = remove + add unless `migrate`).
- Layers as data; `meta` terms governing diffs by layer.

**Exit criteria (met):** the adversarial suite (`src/commit_test.zig`)
passes — L0-targeting diffs rejected, capability escalation rejected
(office-fact `exists` check), a diff weakening its own governing meta rule
rejected by the layer above, dangling-reference diffs rejected with a
dependency list (and the revolutionary variant that carries its closure
commits); a valid statute commits atomically (state-hash equality on
reject), delay keeps diffs staged and fact-visible, and the replay tests
hold with staging active.

## M3 — Procedures (slice 3) ✅ (2026-07-06)

- `procedure` IR (named steps with `requires` exprs), first-class on the
  world like rules/metas; `add_procedure`/`remove_procedure` diff ops with
  remove+add-in-one-diff as replacement. Completion semantics are fixed
  kernel behavior: the final step stages the carried bill with `via`
  rewritten to the procedure name and emits `procedure_done`.
- Instances live on the world (the bill is a `Diff`, not a fact) and mirror
  into a kernel-layer `proc_instance` fact — the `staged_diff` pattern —
  so rules can gate on the current step.
- New ADVANCE pass between APPLY and COMMIT: each instance re-resolves its
  procedure *and* current step by name (§8.1, kernel invariant), advances
  at most one step per tick, and aborts with `procedure_aborted` when the
  procedure or step vanished (§9 — the only abort path; `remove_procedure`
  just removes the definition).
- New `begin` action (starts an instance; missing procedure ⇒ abort event,
  never an error) and `lookup` expr (single-row field read, `param`
  generalized — needed for vote-threshold `requires`).
- Forged-provenance guard: a diff whose `via` names a live procedure must
  have been staged by that procedure's completion (`forged_via` rejection),
  making §2.5 "staged by procedure X" metas trustworthy.
- Fixed a latent use-after-free: the fact store's update queue retained
  capacity from the per-tick arena across ticks.

**Exit criteria (met):** the M3 suite (`src/procedure_test.zig`) passes —
`pass_statute` runs end to end across ticks 4–6 (introduced, voted,
assented, staged, committed) with the bill's rule firing after; a
mid-passage replacement reroutes the remaining steps only (old assent
never runs, new royal seal does); removing the procedure (or its current
step) mid-flight aborts with a kernel event; forged `via` is rejected; the
two-world determinism test and the re-blessed golden digest hold, and the
CLI replays byte-identically.

## M4a — Externally drivable kernel (slice 4a) ✅ (2026-07-06)

The kernel side of the driver contract: external input, machine-readable
output, and draft validation — pure Zig, no LLM anywhere.

- Log protocol: new `begin` entry kind; tick-addressed externals. An
  `event` entry at tick N is delivered in that tick's ACT (kernel-pended
  events first, then log order); a `begin` entry starts a procedure
  instance at the top of ACT — identical timing and semantics to a
  rule-fired `begin`, `forged_via` guard included. `diff` entries stay
  genesis-only (tick 0): bills enter through procedures so the meta rules
  remain the sole gate.
- `World.pendExternal` / `beginExternal`; the CLI fold groups entries by
  tick and runs `max(--ticks, last entry tick)`.
- `--json`: one deterministic NDJSON tick report per line — events
  processed, commit verdicts (reason + deps), and a full fact dump
  (kernel-layer `staged_diff` / `proc_instance` included — pending
  legislation and procedure positions are exactly what personas need).
  Report collection is passive; digests are unaffected.
- `politick check --log … --diff bill.json`: static validation (§9
  passes 1–3, factored out of COMMIT as `World.validateDiff`) of a draft
  against the log's world, with structured diagnostics (`check.Diag`:
  error code + offending symbol/field). Exit 0 ok / 1 rejected or
  undecodable / 2 I/O. Delay and meta-allow evaluation stay COMMIT-only —
  a draft that checks clean can still be voted down; that's the game.
- Fixed latent dangling `deps` slices in the judge (stack temporaries now
  duplicated into the tick arena — the `check` path made them observable).

**Exit criteria (met):** `src/external_test.zig` — an external event
fires at its tick and not before; an external `begin` carries
`pass_statute` end to end from log entries alone; `validateDiff` verdicts
match COMMIT reasons (L0, dangling with diagnostics, unknown target,
default-deny) — and it *is* the COMMIT path, so parity is structural;
attached reports never perturb digests; two-world determinism with
externals interleaved; golden digest unchanged; CLI replay byte-identical.

## M4b — Persona driver (slice 4b) ✅ (2026-07-06)

Python driver (`driver/`, uv-managed) speaking to the kernel only through
the log: appends `event`/`begin` entries, reads `--json` reports, one
kernel invocation per tick (refold each time — O(T²), consistent with
naive derive recompute). Local model instead of a hosted API.

- `log.py` writes envelopes byte-compatible with `log.zig`; `kernel.py`
  wraps run/check/replay as subprocesses.
- Actors: `ScriptedActor` and seeded `RandomActor` remain the test
  harness (kernel vs persona bugs stay distinguishable); `LlmActor` is
  the M4 payoff.
- LLM: llama.cpp `llama-server` via its OpenAI-compatible endpoint;
  `grammar/diff.gbnf` constrains sampling to the diff-object wire format
  with a genuinely recursive `expr` production (stronger than hosted
  structured outputs, which can't express recursion). Two-turn persona
  flow — free-text intent, then grammar-constrained compile — then a ≤3
  retry loop feeding `politick check` diagnostics back (§8.3); the actor
  abstains on exhaustion. Hosted APIs stay a config swap (any
  OpenAI-compatible URL + depth-unrolled schema).
- `worlds/legislature.json`: poll-tax economy + seats + `pass_statute`
  (introduce/floor_vote/assent gated on generic facts, not per-bill rows)
  + the via-checking `amend_statute` meta.
- The CLI (`politick-driver`) re-verifies the exit criterion on every
  run: after driving, it replays the log kernel-only and compares digests.

**Exit criteria (met, CI-mocked):** the pytest suite drives
introduce→vote→assent→commit end to end against the real kernel binary
with a `FakeLlm`, including a draft that is rejected (unknown schema,
diagnostics surfaced in the retry prompt) and fixed on retry; every
driven log replays byte-identically without the driver. The live-model
run is the same loop with a real endpoint:
`llama-server -m <model.gguf>` then
`cd driver && uv run politick-driver --ticks 20 --genesis worlds/legislature.json --llm-url http://127.0.0.1:8080`.

## Deferred (post-M4, unscheduled)

- Salsa-style incremental derives (§6) — only when profiling demands it.
- Priority as legislatable data (lex specialis / lex posterior, §8.2).
- Surface syntax as a display/authoring layer.
- Courts / `interpret` term kind (§7.4 — still an open design question).
- Driver: multi-persona sessions, nested stage/begin in bill grammar,
  a `--follow` kernel mode if the per-tick refold ever hurts.
