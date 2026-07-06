# politick

A fully legislatable country simulator.

Everything above a small kernel — taxes, institutions, elections, the
constitution itself — is expressed in a statute DSL and stored in a versioned
rule database. Laws are *diffs against that database*: staged during a
simulation tick, validated against the meta-rules they touch, and committed
atomically at the tick boundary. LLM personas write bills in natural language,
which are compiled into these diffs.

## Status

Design stage. No code yet — the current work is the DSL and kernel design in
[`docs/dsl-sketch.md`](docs/dsl-sketch.md).

## Core ideas

- **Everything is law, law is data.** The world state is typed facts; game
  logic is rules, derived queries, and procedures stored in a rule database.
  There is no hardcoded "government" — offices, chambers, and voting
  procedures are all legislatable.

- **Layers without special cases.** Statutes, organic law, and the
  constitution are the same kind of object at different layers. A layer is
  just data; entrenchment is an amendment meta-rule that is expensive to
  satisfy. The amendment process is itself amendable.

- **One kernel legal principle.** A diff commits iff the meta-rule governing
  every term it touches is satisfied. The only immutable clause is the Gödel
  boundary: the kernel refuses diffs targeting the evaluator itself.

- **Coups are meta-rule exploits.** A revolution is just a large diff. Whether
  it commits depends on whether the meta-rules allow it — or on a prior diff
  having weakened them first. Historically accurate.

- **Authority as capabilities.** Actions require capabilities granted by
  facts (`office(...)` holds a `Set<Cap>`). The kernel checks possession, not
  legitimacy — legitimacy is emergent from which diffs the meta-rules let
  through.

- **Deterministic and replayable.** Same facts + event order + RNG seed ⇒
  same tick. LLM output enters the system only as diffs or events, so entire
  runs replay from the event/diff log.

## How it evaluates

Each tick runs four phases:

```
READ    derives recompute incrementally from committed facts
ACT     actor policies run; rules fire on events; actions queue
APPLY   fact updates applied; conflicts resolved deterministically
COMMIT  staged diffs validated against meta-rules; commit atomically
```

Rules never observe their own writes, and rule modification is staged — the
program running at tick *t* cannot rewrite itself during *t*.

## Reading more

The full design — the five DSL term kinds (`fact`, `derive`, `rule`,
`procedure`, `meta`), the diff/statute object, phase discipline, and open
design questions — is in [`docs/dsl-sketch.md`](docs/dsl-sketch.md).
