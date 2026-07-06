# Statute DSL — Design Sketch

A rule language for a fully legislatable country simulator. Everything above the
kernel is expressed in this DSL and stored in a versioned rule database.
Statutes are *diffs against that database*, staged during a tick and committed
atomically at the tick boundary.

---

## 1. Layer model

```
┌─────────────────────────────────────────────┐
│ L3  Statutes (ordinary law)     — cheap to amend
│ L2  Organic law (institutions)  — harder meta-rule
│ L1  Constitution                — entrenched meta-rule
│ L0  Kernel (not in DSL)         — tick loop, evaluator,
│                                   diff/commit semantics
└─────────────────────────────────────────────┘
```

Layers are not special-cased in the evaluator. A rule's layer is just data,
and the *meta-rule* for amending that layer is itself a rule (at the same or
higher layer). Entrenchment = an amendment meta-rule that is expensive to
satisfy.

---

## 2. Core terms

Five term kinds. Everything in the simulation is built from these.

### 2.1 `fact` — state schema

Typed relations. The world state is a set of facts.

```
fact treasury(amount: Money)
fact seat(holder: ActorId, chamber: ChamberId)
fact approval(bloc: BlocId, of: ActorId, value: Float)   // Tier-0 state
fact office(name: Symbol, holder: ActorId, powers: Set<Cap>)
```

### 2.2 `derive` — incremental queries (the DAG)

Pure functions over facts. These are the nodes of the salsa-style
incremental-recompute graph. Tier-0 "demographic math" lives here.

```
derive national_mood: Float =
    weighted_mean(approval(bloc, _, v) for bloc, v, weight = population(bloc))

derive quorum(ch: ChamberId): Int =
    ceil(count(seat(_, ch)) * lookup_param("quorum_fraction", ch))
```

`lookup_param` is the late-binding hook: coefficients are facts, so even the
economy's response curves are legislatable.

### 2.3 `rule` — event–condition–action

The reactive layer. Fires on kernel or user-defined events.

```
rule collect_poll_tax
  layer: statute
  on   : tick.quarter
  when : office("tax_collector", _, caps) and caps has Cap::Levy
  do   : for bloc in blocs():
           emit levy(bloc, amount = population(bloc) * param("poll_tax_rate"));
           update approval(bloc, government) by -0.02 * param("tax_resentment")
```

Actions may only:
- `emit` events (delivered next evaluation step, same tick)
- `update` facts (visible next tick — see phase rules, §4)
- `stage` rule-diffs (committed at tick boundary — §5)

No action can call the evaluator recursively. This keeps evaluation
stratified and terminating per tick.

### 2.4 `procedure` — multi-step protocols

Long-running state machines (a bill's life cycle). Sugar over facts + rules,
but first-class so actors can *query* them ("how do I pass a statute?").

```
procedure pass_statute(bill: Diff) -> Committed | Rejected
  layer: organic
  step introduce   : requires seat(sponsor, lower)
  step committee   : requires vote(committee_of(bill.domain), majority)
  step floor_lower : requires vote(lower, majority, quorum(lower))
  step floor_upper : requires vote(upper, majority, quorum(upper))
  step assent      : requires any_of(
                        signature(office_holder("chancellor")),
                        override(lower, two_thirds))
  on Committed     : stage bill
```

Actors discover the current constitution by querying
`rules.lookup(procedure, "pass_statute")` at decision time — never by caching
it. Replace this procedure via a statute, and next tick every persona's
"how do I influence policy" answer changes.

### 2.5 `meta` — amendment rules

Rules about diffs. This is where entrenchment lives.

```
meta amend_statute
  governs: layer = statute
  allow  : diff staged by procedure pass_statute

meta amend_organic
  governs: layer = organic
  allow  : diff staged by procedure pass_statute
           with floor_lower.threshold = 3/5
           and  floor_upper.threshold = 3/5

meta amend_constitution
  governs: layer = constitution
  allow  : diff staged by procedure constitutional_convention
           and delay(ticks = 4)          // must survive 4 ticks staged
           and not_repealable_within(ticks = 20)
```

The kernel's only hardcoded legal principle: **a diff commits iff the meta
rule governing every term it touches is satisfied.** Which meta rule governs
is itself resolved by lookup — so the amendment process is amendable, subject
to *its* meta rule (the standard constitutional regress, terminated by L0:
the kernel refuses diffs against the evaluator itself).

---

## 3. Diffs — the statute object

What LLM personas actually produce (via a constrained compile call from
natural-language bill text):

```
diff "Wool Tariff Repeal Act"
  provenance: sponsor = actor:baron_aldric, via = procedure:pass_statute
  remove rule  wool_tariff
  set    param tariff_rate.wool = 0.0
  add    rule  wool_subsidy { on: tick.quarter, do: ... }
```

Diffs are first-class facts while staged, so rules can react to *pending*
legislation (markets pricing in a tariff repeal, lobbying rules triggering).

A revolutionary statute is just a large diff:

```
diff "Directorate Act"
  remove procedure pass_statute
  remove fact      seat(*, lower), seat(*, upper)
  add    fact      office("director", actor:general_krav, {Cap::Levy, Cap::Decree})
  add    procedure pass_statute(bill) -> ...   // decree by director
```

Whether it can *commit* depends entirely on whether it satisfies the meta
rules it touches — or on a prior diff having weakened those meta rules first.
Coups in this system are meta-rule exploits, which is historically accurate.

---

## 4. Phase discipline (per tick)

```
Phase 0  READ    derives recompute (incrementally) from committed facts
Phase 1  ACT     actor policies run; rules fire on events; actions queue
Phase 2  APPLY   fact updates applied; conflicts resolved by priority, then
                 provenance timestamp (deterministic)
Phase 3  COMMIT  staged diffs validated against meta rules; valid diffs
                 commit atomically; invalidation set pushed to DAG
```

Consequences:
- A rule can never observe its own writes (no intra-tick fixpoints).
- A procedure mid-flight uses the rule set that existed when it *started*
  a step, but each new step re-resolves — so changing the rules mid-passage
  affects remaining steps only. (Alternative: pin the whole procedure to its
  start-of-flight snapshot. Pick one and make it a kernel invariant.)
- Rule modification is staged, exactly like staged metaprogramming: the
  program that runs at phase t cannot rewrite itself during t.

---

## 5. Authority as capabilities

Every rule and diff carries provenance. Actions require capabilities:

```
Cap::Levy, Cap::Decree, Cap::Appoint(office), Cap::Convene(chamber), ...
```

Capabilities are granted by facts (`office(...)` holds a `Set<Cap>`), and
facts are legislatable — so the entire authority structure is userland.
The kernel checks capabilities mechanically; it has no concept of
"legitimacy," only of possession. Legitimacy is an emergent property of
which diffs the meta rules let through.

---

## 6. Evaluation & performance notes

- **Rule DB indexed by event type** → firing is O(rules subscribed to this
  event), not O(all law).
- **Derives are salsa-style memoized nodes**; a commit produces an
  invalidation set; only downstream nodes recompute. Ordinary statutes touch
  a handful of rules → near-zero marginal cost per tick. The "everything
  changes" diff = full flush, one expensive tick.
- **Determinism**: same fact set + same event order + same RNG seed ⇒ same
  tick. All LLM outputs enter the system only as diffs or emitted events, so
  runs are replayable from the event/diff log.
- **The Gödel boundary**: no term may reference the evaluator, the phase
  order, or the diff/commit mechanism. The kernel rejects any diff whose
  target is L0. This is the one immutable clause.

---

## 7. Open design questions

1. **Procedure pinning** (§4): re-resolve per step vs. snapshot at start —
   changes whether mid-passage rule changes are a viable political tactic.
2. **Conflict semantics** in Phase 2: priority lattice vs. last-writer-wins
   vs. reject-and-retry. Priority-as-data means precedence is legislatable
   too (lex specialis / lex posterior as meta rules).
3. **Typed vs. dynamic DSL**: a small static type system over facts/derives
   catches malformed LLM-compiled statutes at validation instead of runtime —
   probably worth it, and it's the phase-distinction-as-types story again.
4. **Courts**: an `interpret` term kind — an LLM call that resolves an
   ambiguous natural-language clause into a DSL patch, recorded as precedent
   (a new rule with provenance `court`). Stare decisis = precedent rules
   outrank fresh interpretation.
