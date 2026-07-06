//! The kernel tick loop: READ → ACT → APPLY → COMMIT. Long-lived state
//! (schemas, rules, rows, IR) lives in the world's IR arena; per-tick
//! transients live in an arena reset at the tick boundary. Allocators are
//! passed per call — World moves by value, so nothing may store a pointer
//! into it.

const std = @import("std");
const intern = @import("intern.zig");
const hash = @import("hash.zig");
const ir = @import("ir.zig");
const store_mod = @import("store.zig");
const interp = @import("interp.zig");
const check = @import("check.zig");

pub const Symbol = intern.Symbol;

const fuel_budget: u32 = 10_000;
/// Termination backstop for same-tick event cascades; events beyond this
/// are dropped deterministically.
const max_events_per_tick: usize = 10_000;

/// Kernel symbols are interned first, before any log content, so their ids
/// are stable across every world.
pub const KernelSyms = struct {
    tick_start: Symbol,
    tick_quarter: Symbol,
    rule_failed: Symbol,
    update_missed: Symbol,
    param: Symbol,
    // diff machinery
    staged_diff: Symbol,
    diff_var: Symbol,
    layer_kernel: Symbol,
    facts_dropped: Symbol,
    diff_committed: Symbol,
    diff_rejected: Symbol,
    // procedure machinery
    proc_instance: Symbol,
    instance_var: Symbol,
    procedure_advanced: Symbol,
    procedure_done: Symbol,
    procedure_aborted: Symbol,
    procedure_step_failed: Symbol,
    // rejection reasons
    r_l0: Symbol,
    r_unknown_target: Symbol,
    r_duplicate: Symbol,
    r_no_meta: Symbol,
    r_dangling: Symbol,
    r_denied: Symbol,
    r_bad_fact: Symbol,
    r_forged_via: Symbol,
};

const StagedDiff = struct {
    diff: *const ir.Diff,
    since_tick: u64,
    seq: u64,
    /// Staged by procedure completion (kernel), not by a rule's `stage`
    /// action. Guards §2.5 "staged by procedure X" meta patterns against
    /// forged `via` provenance.
    by_procedure: bool = false,
};

/// An in-flight procedure instance. The bill is a Diff, so it lives here
/// rather than in a fact row; scalars mirror into the kernel-layer
/// proc_instance fact for rules to query. Position is tracked by step
/// *name* and re-located in the freshly resolved definition every ADVANCE —
/// re-resolve per step (§8.1) with no snapshot.
const ProcInstance = struct {
    id: Symbol,
    procedure: Symbol,
    bill: *const ir.Diff,
    step_name: Symbol,
    since_tick: u64,
};

const Rejection = struct { reason: Symbol, deps: []const Symbol = &.{} };

const Verdict = union(enum) { commit, wait, reject: Rejection };

pub const World = struct {
    gpa: std.mem.Allocator,
    ir_arena: std.heap.ArenaAllocator,
    interner: intern.Interner = .{},
    rng: std.Random.DefaultPrng,
    tick: u64 = 0,
    /// Chained digest: H(prev chain, tick, state hash). A run's identity.
    chain: hash.Digest,
    store: store_mod.FactStore = .{},
    rules: std.ArrayList(ir.Rule) = .empty,
    metas: std.ArrayList(ir.Meta) = .empty,
    procedures: std.ArrayList(ir.Procedure) = .empty,
    rules_by_event: std.AutoArrayHashMapUnmanaged(Symbol, std.ArrayList(u32)) = .empty,
    staged: std.ArrayList(StagedDiff) = .empty,
    instances: std.ArrayList(ProcInstance) = .empty,
    /// Kernel events raised outside ACT, delivered next tick.
    pending: std.ArrayList(interp.Event) = .empty,
    seq: u64 = 0,
    syms: KernelSyms,

    pub fn init(gpa: std.mem.Allocator, seed: u64) !World {
        var h = hash.StateHasher.init();
        h.writeBytes("politick.chain.v1");
        var interner: intern.Interner = .{};
        errdefer interner.deinit(gpa);
        const syms = KernelSyms{
            .tick_start = try interner.intern(gpa, "tick.start"),
            .tick_quarter = try interner.intern(gpa, "tick.quarter"),
            .rule_failed = try interner.intern(gpa, "rule_failed"),
            .update_missed = try interner.intern(gpa, "update_missed"),
            .param = try interner.intern(gpa, "param"),
            .staged_diff = try interner.intern(gpa, "staged_diff"),
            .diff_var = try interner.intern(gpa, "diff"),
            .layer_kernel = try interner.intern(gpa, "kernel"),
            .facts_dropped = try interner.intern(gpa, "facts_dropped"),
            .diff_committed = try interner.intern(gpa, "diff_committed"),
            .diff_rejected = try interner.intern(gpa, "diff_rejected"),
            .proc_instance = try interner.intern(gpa, "proc_instance"),
            .instance_var = try interner.intern(gpa, "instance"),
            .procedure_advanced = try interner.intern(gpa, "procedure_advanced"),
            .procedure_done = try interner.intern(gpa, "procedure_done"),
            .procedure_aborted = try interner.intern(gpa, "procedure_aborted"),
            .procedure_step_failed = try interner.intern(gpa, "procedure_step_failed"),
            .r_l0 = try interner.intern(gpa, "l0_target"),
            .r_unknown_target = try interner.intern(gpa, "unknown_target"),
            .r_duplicate = try interner.intern(gpa, "duplicate_term"),
            .r_no_meta = try interner.intern(gpa, "no_meta"),
            .r_dangling = try interner.intern(gpa, "dangling_refs"),
            .r_denied = try interner.intern(gpa, "meta_denied"),
            .r_bad_fact = try interner.intern(gpa, "bad_fact"),
            .r_forged_via = try interner.intern(gpa, "forged_via"),
        };
        // Intern everything before the interner moves into the World value;
        // interning afterwards through a copy could realloc and leave the
        // errdefer's handle stale.
        const f_name = try interner.intern(gpa, "name");
        const f_layer = try interner.intern(gpa, "layer");
        const f_by = try interner.intern(gpa, "by");
        const f_via = try interner.intern(gpa, "via");
        const f_since = try interner.intern(gpa, "since_tick");
        const f_id = try interner.intern(gpa, "id");
        const f_procedure = try interner.intern(gpa, "procedure");
        const f_step = try interner.intern(gpa, "step");

        var world = World{
            .gpa = gpa,
            .ir_arena = std.heap.ArenaAllocator.init(gpa),
            .interner = interner,
            .rng = std.Random.DefaultPrng.init(seed),
            .chain = h.finish(),
            .syms = syms,
        };
        errdefer world.ir_arena.deinit();
        // The staged_diff schema is kernel-layer: the L0 guard makes it
        // untouchable by diffs, and its rows are what meta allow exprs bind.
        // (The transient arena handle is safe here: allocations survive the
        // by-value return; the handle itself is not stored.)
        const arena = world.ir_arena.allocator();
        const fields = try arena.dupe(ir.Field, &.{
            .{ .name = f_name, .ty = .symbol },
            .{ .name = f_layer, .ty = .symbol },
            .{ .name = f_by, .ty = .symbol },
            .{ .name = f_via, .ty = .symbol },
            .{ .name = f_since, .ty = .int },
        });
        try world.store.addSchema(arena, .{
            .name = syms.staged_diff,
            .fields = fields,
            .key_len = 1,
            .layer = syms.layer_kernel,
        });
        // proc_instance mirrors in-flight procedure instances (same pattern:
        // kernel-layer, rows written only by the kernel in ADVANCE).
        const inst_fields = try arena.dupe(ir.Field, &.{
            .{ .name = f_id, .ty = .symbol },
            .{ .name = f_procedure, .ty = .symbol },
            .{ .name = f_step, .ty = .symbol },
            .{ .name = f_by, .ty = .symbol },
            .{ .name = f_since, .ty = .int },
        });
        try world.store.addSchema(arena, .{
            .name = syms.proc_instance,
            .fields = inst_fields,
            .key_len = 1,
            .layer = syms.layer_kernel,
        });
        return world;
    }

    pub fn deinit(self: *World) void {
        self.interner.deinit(self.gpa);
        self.ir_arena.deinit();
    }

    /// Pre-tick-1 application of decoded diff ops — the kernel-privileged
    /// bootstrap, no meta validation. Ops must be allocated in this world's
    /// IR arena (decode with `irAllocator()`).
    pub fn applyGenesis(self: *World, ops: []const ir.DiffOp) !void {
        try self.applyOps(ops);
    }

    /// The one apply path (§9: apply is total). COMMIT pre-validates so
    /// only OOM can fail there; genesis relies on the same store checks
    /// erroring out loudly instead.
    fn applyOps(self: *World, ops: []const ir.DiffOp) !void {
        const arena = self.ir_arena.allocator();
        for (ops) |op| switch (op) {
            .add_schema => |schema| try self.store.addSchema(arena, schema),
            .add_rule => |rule| {
                try self.rules.append(arena, rule);
                try self.indexRule(@intCast(self.rules.items.len - 1));
            },
            .add_meta => |meta| try self.metas.append(arena, meta),
            .add_procedure => |proc| try self.procedures.append(arena, proc),
            .add_fact => |fact| try self.store.insert(arena, fact.schema, fact.values),
            .remove_schema => |name| {
                const count = self.store.removeSchema(name);
                try self.pendKernel(self.syms.facts_dropped, &.{
                    .{ .symbol = name },
                    .{ .int = @intCast(count) },
                });
            },
            .remove_rule => |name| {
                for (self.rules.items, 0..) |r, i| {
                    if (r.name == name) {
                        _ = self.rules.orderedRemove(i);
                        break;
                    }
                }
                try self.rebuildRuleIndex();
            },
            .remove_meta => |name| {
                for (self.metas.items, 0..) |m, i| {
                    if (m.name == name) {
                        _ = self.metas.orderedRemove(i);
                        break;
                    }
                }
            },
            // In-flight instances are untouched here: the next ADVANCE
            // re-resolves, finds nothing, and aborts them (§9).
            .remove_procedure => |name| {
                for (self.procedures.items, 0..) |p, i| {
                    if (p.name == name) {
                        _ = self.procedures.orderedRemove(i);
                        break;
                    }
                }
            },
            .remove_fact => |rf| _ = self.store.removeFact(rf.schema, rf.key),
        };
    }

    fn indexRule(self: *World, idx: u32) !void {
        const arena = self.ir_arena.allocator();
        const gop = try self.rules_by_event.getOrPut(arena, self.rules.items[idx].on);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, idx);
    }

    fn rebuildRuleIndex(self: *World) !void {
        self.rules_by_event.clearRetainingCapacity();
        for (0..self.rules.items.len) |i| {
            try self.indexRule(@intCast(i));
        }
    }

    /// Queue a kernel event for delivery next tick. Args are duplicated
    /// into the IR arena so they outlive the current tick arena.
    fn pendKernel(self: *World, name: Symbol, args: []const interp.Value) !void {
        const arena = self.ir_arena.allocator();
        try self.pending.append(arena, .{ .name = name, .args = try arena.dupe(interp.Value, args) });
    }

    pub fn irAllocator(self: *World) std.mem.Allocator {
        return self.ir_arena.allocator();
    }

    /// Run one tick; returns the new chain digest.
    pub fn step(self: *World) !hash.Digest {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const ta = arena.allocator();

        self.tick += 1;

        // Phase 0 READ: no-op — derives are hardcoded pure fns for now,
        // computed on demand (dsl-sketch.md §11 "naive evaluation first").

        // Phase 1 ACT
        try self.phaseAct(ta);

        // Phase 2 APPLY
        var missed: std.ArrayList(Symbol) = .empty;
        try self.store.applyQueued(ta, &missed);
        for (missed.items) |schema_sym| {
            try self.pendKernel(self.syms.update_missed, &.{.{ .symbol = schema_sym }});
        }
        // Newly staged diffs become facts here — visible to rules from the
        // next tick's ACT, like every other write.
        for (self.staged.items) |sd| {
            if (sd.since_tick == self.tick) {
                try self.materializeStagedFact(sd.diff, sd.since_tick);
            }
        }

        // Phase 2.5 ADVANCE: procedure instances re-resolve and step.
        try self.phaseAdvance(ta);

        // Phase 3 COMMIT
        try self.phaseCommit(ta);

        var h = hash.StateHasher.init();
        h.writeBytes("politick.chain.v1");
        h.writeBytes(&self.chain);
        h.writeU64(self.tick);
        const state = try self.stateHash(ta);
        h.writeBytes(&state);
        self.chain = h.finish();
        return self.chain;
    }

    fn phaseAct(self: *World, ta: std.mem.Allocator) !void {
        var queue: std.ArrayList(interp.Event) = .empty;
        try queue.appendSlice(ta, self.pending.items);
        self.pending.clearRetainingCapacity();
        try queue.append(ta, .{ .name = self.syms.tick_start, .args = &.{} });
        if (self.tick % 4 == 0) {
            try queue.append(ta, .{ .name = self.syms.tick_quarter, .args = &.{} });
        }

        // Cursor loop: events emitted by rules append to the queue and are
        // processed in the same tick, capped for termination.
        var cursor: usize = 0;
        while (cursor < queue.items.len and cursor < max_events_per_tick) : (cursor += 1) {
            const event = queue.items[cursor];
            const subscribed = self.rules_by_event.get(event.name) orelse continue;
            for (subscribed.items) |rule_idx| {
                try self.fireRule(ta, &self.rules.items[rule_idx], &queue);
            }
        }
    }

    fn fireRule(self: *World, ta: std.mem.Allocator, rule: *const ir.Rule, queue: *std.ArrayList(interp.Event)) !void {
        var ctx = interp.Ctx{
            .ta = ta,
            .store = &self.store,
            .param_schema = self.syms.param,
            .fuel = fuel_budget,
            .priority = rule.priority,
            .next_seq = &self.seq,
        };
        const fired = interp.runRule(&ctx, rule) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Rule failure is atomic: staged actions are dropped (they only
            // live in ctx) and the failure becomes a kernel event this tick.
            else => {
                const args = try ta.dupe(interp.Value, &.{.{ .symbol = rule.name }});
                try queue.append(ta, .{ .name = self.syms.rule_failed, .args = args });
                return;
            },
        };
        if (!fired) return;
        for (ctx.staged_updates.items) |u| {
            try self.store.queueUpdate(ta, u);
        }
        try queue.appendSlice(ta, ctx.staged_events.items);
        for (ctx.staged_diffs.items) |diff| {
            try self.stageDiff(diff, false);
        }
        for (ctx.staged_begins.items) |b| {
            try self.beginInstance(b);
        }
    }

    /// Re-staging a name replaces the earlier staged diff (deterministic:
    /// staging order is rule order).
    fn stageDiff(self: *World, diff: *const ir.Diff, by_procedure: bool) !void {
        for (self.staged.items, 0..) |sd, i| {
            if (sd.diff.name == diff.name) {
                _ = self.staged.orderedRemove(i);
                break;
            }
        }
        self.seq += 1;
        try self.staged.append(self.ir_arena.allocator(), .{
            .diff = diff,
            .since_tick = self.tick,
            .seq = self.seq,
            .by_procedure = by_procedure,
        });
    }

    fn materializeStagedFact(self: *World, diff: *const ir.Diff, since_tick: u64) !void {
        try self.store.insert(self.ir_arena.allocator(), self.syms.staged_diff, &.{
            .{ .symbol = diff.name },
            .{ .symbol = diff.layer },
            .{ .symbol = diff.by },
            .{ .symbol = diff.via },
            .{ .int = @intCast(since_tick) },
        });
    }

    /// A begin resolves its procedure at fire time (§2.4) — a missing
    /// procedure is a defined runtime outcome (abort event), never an
    /// error. Re-beginning an id replaces the in-flight instance, like
    /// re-staging a diff.
    fn beginInstance(self: *World, b: ir.Action.Begin) !void {
        for (self.instances.items, 0..) |inst, i| {
            if (inst.id == b.bill.name) {
                _ = self.store.removeFact(self.syms.proc_instance, &.{.{ .symbol = inst.id }});
                _ = self.instances.orderedRemove(i);
                break;
            }
        }
        const proc = self.findProcedure(b.procedure) orelse {
            try self.pendKernel(self.syms.procedure_aborted, &.{
                .{ .symbol = b.bill.name },
                .{ .symbol = b.procedure },
            });
            return;
        };
        try self.instances.append(self.ir_arena.allocator(), .{
            .id = b.bill.name,
            .procedure = b.procedure,
            .bill = b.bill,
            .step_name = proc.steps[0].name,
            .since_tick = self.tick,
        });
    }

    /// Phase 2.5 ADVANCE. Every in-flight instance re-resolves its procedure
    /// and current step by name (§8.1 — no snapshot), so a definition change
    /// affects remaining steps only; a vanished procedure or step aborts the
    /// instance with a kernel event (§9). A satisfied `requires` advances at
    /// most one step per tick, so passage is genuinely multi-tick and every
    /// step is observable through the proc_instance fact.
    fn phaseAdvance(self: *World, ta: std.mem.Allocator) !void {
        var i: usize = 0;
        while (i < self.instances.items.len) {
            const inst = self.instances.items[i];
            const proc = self.findProcedure(inst.procedure) orelse {
                try self.abortInstance(i);
                continue;
            };
            const step_idx = proc.stepIndex(inst.step_name) orelse {
                try self.abortInstance(i);
                continue;
            };
            // The requires expr sees the instance as a transient row bound
            // to `instance` — built here because new instances have no
            // materialized fact row yet.
            const row = try ta.dupe(interp.Value, &.{
                .{ .symbol = inst.id },
                .{ .symbol = inst.procedure },
                .{ .symbol = inst.step_name },
                .{ .symbol = inst.bill.by },
                .{ .int = @intCast(inst.since_tick) },
            });
            var ictx = interp.Ctx{
                .ta = ta,
                .store = &self.store,
                .param_schema = self.syms.param,
                .fuel = fuel_budget,
                .priority = 0,
                .next_seq = &self.seq,
            };
            ictx.bind(self.syms.instance_var, self.syms.proc_instance, row);
            const satisfied = blk: {
                const v = interp.eval(&ictx, proc.steps[step_idx].requires) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        try self.pendKernel(self.syms.procedure_step_failed, &.{
                            .{ .symbol = inst.id },
                            .{ .symbol = inst.step_name },
                        });
                        break :blk false;
                    },
                };
                if (v != .boolean) {
                    try self.pendKernel(self.syms.procedure_step_failed, &.{
                        .{ .symbol = inst.id },
                        .{ .symbol = inst.step_name },
                    });
                    break :blk false;
                }
                break :blk v.boolean;
            };
            if (!satisfied) {
                try self.upsertInstanceFact(inst);
                i += 1;
            } else if (step_idx + 1 < proc.steps.len) {
                self.instances.items[i].step_name = proc.steps[step_idx + 1].name;
                try self.pendKernel(self.syms.procedure_advanced, &.{
                    .{ .symbol = inst.id },
                    .{ .symbol = self.instances.items[i].step_name },
                });
                try self.upsertInstanceFact(self.instances.items[i]);
                i += 1;
            } else {
                // Final step satisfied: stage the bill with its provenance
                // rewritten to the procedure that actually carried it —
                // this is what §2.5 "staged by procedure X" metas trust.
                const arena = self.ir_arena.allocator();
                const bill = try arena.create(ir.Diff);
                bill.* = inst.bill.*;
                bill.via = inst.procedure;
                try self.stageDiff(bill, true);
                // Materialize its staged_diff fact now: judge Pass 4 binds
                // this row at the same tick's COMMIT.
                try self.materializeStagedFact(bill, self.tick);
                try self.pendKernel(self.syms.procedure_done, &.{
                    .{ .symbol = inst.id },
                    .{ .symbol = inst.procedure },
                });
                _ = self.store.removeFact(self.syms.proc_instance, &.{.{ .symbol = inst.id }});
                _ = self.instances.orderedRemove(i);
            }
        }
    }

    fn abortInstance(self: *World, i: usize) !void {
        const inst = self.instances.items[i];
        try self.pendKernel(self.syms.procedure_aborted, &.{
            .{ .symbol = inst.id },
            .{ .symbol = inst.procedure },
        });
        _ = self.store.removeFact(self.syms.proc_instance, &.{.{ .symbol = inst.id }});
        _ = self.instances.orderedRemove(i);
    }

    fn upsertInstanceFact(self: *World, inst: ProcInstance) !void {
        try self.store.insert(self.ir_arena.allocator(), self.syms.proc_instance, &.{
            .{ .symbol = inst.id },
            .{ .symbol = inst.procedure },
            .{ .symbol = inst.step_name },
            .{ .symbol = inst.bill.by },
            .{ .int = @intCast(inst.since_tick) },
        });
    }

    fn phaseCommit(self: *World, ta: std.mem.Allocator) !void {
        var i: usize = 0;
        while (i < self.staged.items.len) {
            const sd = self.staged.items[i];
            const verdict = try self.judge(ta, sd);
            switch (verdict) {
                .wait => {
                    i += 1;
                    continue;
                },
                .commit => {
                    try self.applyOps(sd.diff.ops);
                    try self.pendKernel(self.syms.diff_committed, &.{.{ .symbol = sd.diff.name }});
                },
                .reject => |r| {
                    var args: std.ArrayList(interp.Value) = .empty;
                    try args.append(ta, .{ .symbol = sd.diff.name });
                    try args.append(ta, .{ .symbol = r.reason });
                    for (r.deps) |d| try args.append(ta, .{ .symbol = d });
                    try self.pendKernel(self.syms.diff_rejected, args.items);
                },
            }
            // Committed or rejected: unstage the diff and its fact.
            _ = self.store.removeFact(self.syms.staged_diff, &.{.{ .symbol = sd.diff.name }});
            _ = self.staged.orderedRemove(i);
        }
    }

    /// The kernel's one legal principle plus the §9 validation order:
    /// targets/L0/duplicates → closure/type → governing metas exist →
    /// delay → every governing meta allows.
    fn judge(self: *World, ta: std.mem.Allocator, sd: StagedDiff) !Verdict {
        const diff = sd.diff;
        var touched_layers: std.ArrayList(Symbol) = .empty;
        var removed_schemas: std.ArrayList(Symbol) = .empty;
        var added_schemas: std.ArrayList(ir.Schema) = .empty;
        var removed_procedures: std.ArrayList(Symbol) = .empty;

        // A diff whose `via` names a live procedure must actually have been
        // staged by that procedure's completion — otherwise any rule could
        // counterfeit the provenance that §2.5 metas gate on.
        if (!sd.by_procedure and self.findProcedure(diff.via) != null)
            return .{ .reject = .{ .reason = self.syms.r_forged_via, .deps = &.{diff.via} } };

        // Pass 1: every op's target must exist (removes) or be new
        // (adds), must not touch layer "kernel", and contributes its
        // term's layer to the governed set.
        for (diff.ops) |op| {
            const layer: Symbol = switch (op) {
                .add_schema => |s| blk: {
                    if (self.store.schemas.contains(s.name) and !containsSym(removed_schemas.items, s.name))
                        return .{ .reject = .{ .reason = self.syms.r_duplicate, .deps = &.{s.name} } };
                    try added_schemas.append(ta, s);
                    break :blk s.layer;
                },
                .add_rule => |r| blk: {
                    if (self.findRule(r.name) != null)
                        return .{ .reject = .{ .reason = self.syms.r_duplicate, .deps = &.{r.name} } };
                    break :blk r.layer;
                },
                .add_meta => |m| blk: {
                    if (self.findMeta(m.name) != null)
                        return .{ .reject = .{ .reason = self.syms.r_duplicate, .deps = &.{m.name} } };
                    break :blk m.layer;
                },
                // Remove+add of the same name in one diff is replacement —
                // the mid-passage amendment tactic (§8.1) — so the duplicate
                // check honors this diff's own removes, like schemas do.
                .add_procedure => |p| blk: {
                    if (self.findProcedure(p.name) != null and !containsSym(removed_procedures.items, p.name))
                        return .{ .reject = .{ .reason = self.syms.r_duplicate, .deps = &.{p.name} } };
                    break :blk p.layer;
                },
                .remove_schema => |name| blk: {
                    const schema = self.store.schemas.get(name) orelse
                        return .{ .reject = .{ .reason = self.syms.r_unknown_target, .deps = &.{name} } };
                    try removed_schemas.append(ta, name);
                    break :blk schema.layer;
                },
                .remove_rule => |name| blk: {
                    const rule = self.findRule(name) orelse
                        return .{ .reject = .{ .reason = self.syms.r_unknown_target, .deps = &.{name} } };
                    break :blk rule.layer;
                },
                .remove_meta => |name| blk: {
                    const meta = self.findMeta(name) orelse
                        return .{ .reject = .{ .reason = self.syms.r_unknown_target, .deps = &.{name} } };
                    break :blk meta.layer;
                },
                .remove_procedure => |name| blk: {
                    const proc = self.findProcedure(name) orelse
                        return .{ .reject = .{ .reason = self.syms.r_unknown_target, .deps = &.{name} } };
                    try removed_procedures.append(ta, name);
                    break :blk proc.layer;
                },
                .add_fact => |f| blk: {
                    const schema = self.lookupSchemaIn(f.schema, added_schemas.items) orelse
                        return .{ .reject = .{ .reason = self.syms.r_unknown_target, .deps = &.{f.schema} } };
                    if (f.values.len != schema.fields.len)
                        return .{ .reject = .{ .reason = self.syms.r_bad_fact, .deps = &.{f.schema} } };
                    for (f.values, schema.fields) |v, fld| {
                        _ = store_mod.coerce(fld.ty, v) catch
                            return .{ .reject = .{ .reason = self.syms.r_bad_fact, .deps = &.{f.schema} } };
                    }
                    break :blk schema.layer;
                },
                .remove_fact => |rf| blk: {
                    const schema = self.lookupSchemaIn(rf.schema, added_schemas.items) orelse
                        return .{ .reject = .{ .reason = self.syms.r_unknown_target, .deps = &.{rf.schema} } };
                    break :blk schema.layer;
                },
            };
            if (layer == self.syms.layer_kernel)
                return .{ .reject = .{ .reason = self.syms.r_l0 } };
            if (!containsSym(touched_layers.items, layer)) try touched_layers.append(ta, layer);
        }

        // Pass 2: closure + static checks against the post-diff schema view.
        const view = check.SchemaView{
            .base = &self.store.schemas,
            .removed = removed_schemas.items,
            .added = added_schemas.items,
        };
        const ctx = check.Ctx{
            .view = view,
            .param_schema = self.syms.param,
            .prebound = &.{.{ .name = self.syms.diff_var, .schema = self.syms.staged_diff }},
        };

        if (removed_schemas.items.len > 0) {
            var deps: std.ArrayList(Symbol) = .empty;
            for (removed_schemas.items) |gone| {
                for (self.rules.items) |r| {
                    if (diffRemoves(diff, .remove_rule, r.name)) continue;
                    if (check.ruleRefersToSchema(r, gone, self.syms.param)) try deps.append(ta, r.name);
                }
                for (self.metas.items) |m| {
                    if (diffRemoves(diff, .remove_meta, m.name)) continue;
                    if (check.metaRefersToSchema(m, gone, self.syms.param)) try deps.append(ta, m.name);
                }
                for (self.procedures.items) |p| {
                    if (diffRemoves(diff, .remove_procedure, p.name)) continue;
                    if (check.procedureRefersToSchema(p, gone, self.syms.param)) try deps.append(ta, p.name);
                }
                for (diff.ops) |op| switch (op) {
                    .add_rule => |r| if (check.ruleRefersToSchema(r, gone, self.syms.param)) try deps.append(ta, r.name),
                    .add_meta => |m| if (check.metaRefersToSchema(m, gone, self.syms.param)) try deps.append(ta, m.name),
                    .add_procedure => |p| if (check.procedureRefersToSchema(p, gone, self.syms.param)) try deps.append(ta, p.name),
                    else => {},
                };
            }
            if (deps.items.len > 0)
                return .{ .reject = .{ .reason = self.syms.r_dangling, .deps = deps.items } };
        }
        // Procedure requires exprs check under the binding ADVANCE injects.
        const proc_ctx = check.Ctx{
            .view = view,
            .param_schema = self.syms.param,
            .prebound = &.{.{ .name = self.syms.instance_var, .schema = self.syms.proc_instance }},
        };
        for (diff.ops) |op| switch (op) {
            .add_rule => |r| check.checkRule(&ctx, r) catch
                return .{ .reject = .{ .reason = self.syms.r_dangling, .deps = &.{r.name} } },
            .add_meta => |m| check.checkMetaAllow(&ctx, m) catch
                return .{ .reject = .{ .reason = self.syms.r_dangling, .deps = &.{m.name} } },
            .add_procedure => |p| check.checkProcedure(&proc_ctx, p) catch
                return .{ .reject = .{ .reason = self.syms.r_dangling, .deps = &.{p.name} } },
            else => {},
        };

        // Pass 3: governance. Every touched layer needs at least one meta;
        // default-deny otherwise. Delay = max over governing metas.
        var max_delay: u32 = 0;
        for (touched_layers.items) |layer| {
            var governed = false;
            for (self.metas.items) |m| {
                if (m.governs_layer == layer) {
                    governed = true;
                    max_delay = @max(max_delay, m.min_staged_ticks);
                }
            }
            if (!governed)
                return .{ .reject = .{ .reason = self.syms.r_no_meta, .deps = &.{layer} } };
        }
        if (self.tick - sd.since_tick < max_delay) return .wait;

        // Pass 4: every governing meta must allow, evaluated with the
        // staged_diff fact row bound to `diff`.
        const diff_row = self.store.get(self.syms.staged_diff, &.{.{ .symbol = diff.name }}).?;
        for (self.metas.items) |m| {
            if (!containsSym(touched_layers.items, m.governs_layer)) continue;
            var ictx = interp.Ctx{
                .ta = ta,
                .store = &self.store,
                .param_schema = self.syms.param,
                .fuel = fuel_budget,
                .priority = 0,
                .next_seq = &self.seq,
            };
            ictx.bind(self.syms.diff_var, self.syms.staged_diff, diff_row);
            const allowed = interp.eval(&ictx, m.allow) catch
                return .{ .reject = .{ .reason = self.syms.r_denied, .deps = &.{m.name} } };
            if (allowed != .boolean or !allowed.boolean)
                return .{ .reject = .{ .reason = self.syms.r_denied, .deps = &.{m.name} } };
        }

        return .commit;
    }

    fn findRule(self: *const World, name: Symbol) ?*const ir.Rule {
        for (self.rules.items) |*r| {
            if (r.name == name) return r;
        }
        return null;
    }

    fn findMeta(self: *const World, name: Symbol) ?*const ir.Meta {
        for (self.metas.items) |*m| {
            if (m.name == name) return m;
        }
        return null;
    }

    /// The §2.4 decision-time lookup: ADVANCE, begin actions, and the judge
    /// all resolve procedures through here, fresh every time — never cached.
    pub fn findProcedure(self: *const World, name: Symbol) ?*const ir.Procedure {
        for (self.procedures.items) |*p| {
            if (p.name == name) return p;
        }
        return null;
    }

    fn lookupSchemaIn(self: *const World, name: Symbol, added: []const ir.Schema) ?ir.Schema {
        for (added) |s| {
            if (s.name == name) return s;
        }
        return self.store.schemas.get(name);
    }


    /// Facts + term identities. Identity (kind, name, layer, on, priority)
    /// suffices while diffs only add/remove whole terms; structural expr
    /// hashing becomes necessary once in-place term mutation exists.
    pub fn stateHash(self: *World, scratch: std.mem.Allocator) !hash.Digest {
        var h = hash.StateHasher.init();
        try self.store.feedStateHash(scratch, &h);

        h.writeBytes("rules.v1");
        h.writeU64(self.rules.items.len);
        const rule_order = try sortedIndices(scratch, self.rules.items.len, self.rules.items, ruleIdLessThan);
        for (rule_order) |i| {
            const r = self.rules.items[i];
            h.writeU32(r.name.index());
            h.writeU32(r.on.index());
            h.writeU32(r.layer.index());
            h.writeU32(@bitCast(r.priority));
        }

        h.writeBytes("metas.v1");
        h.writeU64(self.metas.items.len);
        const meta_order = try sortedIndices(scratch, self.metas.items.len, self.metas.items, metaIdLessThan);
        for (meta_order) |i| {
            const m = self.metas.items[i];
            h.writeU32(m.name.index());
            h.writeU32(m.layer.index());
            h.writeU32(m.governs_layer.index());
            h.writeU32(m.min_staged_ticks);
        }

        // Instances are covered through their proc_instance facts; bill
        // contents are not hashed, consistent with staged diffs (only the
        // staged_diff fact is).
        h.writeBytes("procedures.v1");
        h.writeU64(self.procedures.items.len);
        const proc_order = try sortedIndices(scratch, self.procedures.items.len, self.procedures.items, procIdLessThan);
        for (proc_order) |i| {
            const p = self.procedures.items[i];
            h.writeU32(p.name.index());
            h.writeU32(p.layer.index());
            h.writeU64(p.steps.len);
            for (p.steps) |s| h.writeU32(s.name.index());
        }
        return h.finish();
    }
};

fn sortedIndices(scratch: std.mem.Allocator, len: usize, items: anytype, comptime lessThan: anytype) ![]usize {
    const order = try scratch.alloc(usize, len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, items, lessThan);
    return order;
}

fn ruleIdLessThan(items: []const ir.Rule, a: usize, b: usize) bool {
    const ra = items[a];
    const rb = items[b];
    if (ra.name != rb.name) return ra.name.index() < rb.name.index();
    return ra.on.index() < rb.on.index();
}

fn metaIdLessThan(items: []const ir.Meta, a: usize, b: usize) bool {
    const ma = items[a];
    const mb = items[b];
    if (ma.name != mb.name) return ma.name.index() < mb.name.index();
    return ma.governs_layer.index() < mb.governs_layer.index();
}

fn procIdLessThan(items: []const ir.Procedure, a: usize, b: usize) bool {
    const pa = items[a];
    const pb = items[b];
    if (pa.name != pb.name) return pa.name.index() < pb.name.index();
    return pa.layer.index() < pb.layer.index();
}

fn diffRemoves(diff: *const ir.Diff, comptime kind: std.meta.Tag(ir.DiffOp), name: Symbol) bool {
    for (diff.ops) |op| {
        if (op == kind and @field(op, @tagName(kind)) == name) return true;
    }
    return false;
}

fn containsSym(items: []const Symbol, sym: Symbol) bool {
    for (items) |s| {
        if (s == sym) return true;
    }
    return false;
}

const testing = std.testing;

test "same seed and tick count reproduce the chain digest" {
    const gpa = testing.allocator;

    var w1 = try World.init(gpa, 42);
    defer w1.deinit();
    var w2 = try World.init(gpa, 42);
    defer w2.deinit();

    var last1: hash.Digest = undefined;
    var last2: hash.Digest = undefined;
    for (0..100) |_| {
        last1 = try w1.step();
        last2 = try w2.step();
    }
    try testing.expectEqualSlices(u8, &last1, &last2);
}

test "chain digest distinguishes tick counts" {
    const gpa = testing.allocator;
    var w = try World.init(gpa, 42);
    defer w.deinit();
    const d1 = try w.step();
    const d2 = try w.step();
    try testing.expect(!std.mem.eql(u8, &d1, &d2));
}

/// Genesis helper for tests: decode a diff payload from JSON and apply it.
fn genesis(w: *World, source: []const u8) !void {
    var decode_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer decode_arena.deinit();
    var decoder = ir.Decoder.init(w.irAllocator(), w.gpa, &w.interner);
    defer decoder.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, decode_arena.allocator(), source, .{});
    try w.applyGenesis(try decoder.decodePayload(parsed));
}

const counter_genesis =
    \\[
    \\ {"add_schema":{"name":"counter","fields":[["id","symbol"],["n","int"]],"key":1}},
    \\ {"add_fact":{"schema":"counter","values":["c",0]}},
    \\ {"add_rule":{"name":"bump","on":"tick.quarter","when":{"lit":true},"do":[
    \\   {"update":{"schema":"counter","key":[{"lit":"c"}],"field":"n","op":"add","value":{"lit":1}}}
    \\ ]}}
    \\]
;

test "rules fire only on their event: quarter rule mutates every 4th tick" {
    const gpa = testing.allocator;
    var w = try World.init(gpa, 1);
    defer w.deinit();
    try genesis(&w, counter_genesis);

    const counter = try w.interner.intern(gpa, "counter");
    const c = try w.interner.intern(gpa, "c");
    for (0..10) |_| _ = try w.step();
    // Ticks 4 and 8 fired.
    const row = w.store.get(counter, &.{.{ .symbol = c }}).?;
    try testing.expectEqual(interp.Value{ .int = 2 }, row[1]);
}

test "emitted events cascade within the same tick" {
    const gpa = testing.allocator;
    var w = try World.init(gpa, 1);
    defer w.deinit();
    try genesis(&w,
        \\[
        \\ {"add_schema":{"name":"flag","fields":[["id","symbol"],["set","boolean"]],"key":1}},
        \\ {"add_fact":{"schema":"flag","values":["f",false]}},
        \\ {"add_rule":{"name":"pinger","on":"tick.start","when":{"lit":true},"do":[
        \\   {"emit":{"event":"ping","args":[]}}
        \\ ]}},
        \\ {"add_rule":{"name":"ponger","on":"ping","when":{"lit":true},"do":[
        \\   {"update":{"schema":"flag","key":[{"lit":"f"}],"field":"set","op":"set","value":{"lit":true}}}
        \\ ]}}
        \\]
    );
    _ = try w.step();
    const flag = try w.interner.intern(gpa, "flag");
    const f = try w.interner.intern(gpa, "f");
    try testing.expectEqual(interp.Value{ .boolean = true }, w.store.get(flag, &.{.{ .symbol = f }}).?[1]);
}

test "failing rule is atomic and raises rule_failed" {
    const gpa = testing.allocator;
    var w = try World.init(gpa, 1);
    defer w.deinit();
    // divide-by-zero after staging one update: neither lands.
    try genesis(&w,
        \\[
        \\ {"add_schema":{"name":"counter","fields":[["id","symbol"],["n","int"]],"key":1}},
        \\ {"add_schema":{"name":"witness","fields":[["id","symbol"],["n","int"]],"key":1}},
        \\ {"add_fact":{"schema":"counter","values":["c",0]}},
        \\ {"add_fact":{"schema":"witness","values":["w",0]}},
        \\ {"add_rule":{"name":"bad","on":"tick.start","when":{"lit":true},"do":[
        \\   {"update":{"schema":"counter","key":[{"lit":"c"}],"field":"n","op":"add","value":{"lit":1}}},
        \\   {"update":{"schema":"counter","key":[{"lit":"c"}],"field":"n","op":"add","value":{"bin":["div",{"lit":1},{"lit":0}]}}}
        \\ ]}},
        \\ {"add_rule":{"name":"watcher","on":"rule_failed","when":{"lit":true},"do":[
        \\   {"update":{"schema":"witness","key":[{"lit":"w"}],"field":"n","op":"add","value":{"lit":1}}}
        \\ ]}}
        \\]
    );
    _ = try w.step();
    const counter = try w.interner.intern(gpa, "counter");
    const witness = try w.interner.intern(gpa, "witness");
    const c = try w.interner.intern(gpa, "c");
    const wsym = try w.interner.intern(gpa, "w");
    // The bad rule's first update must not have landed…
    try testing.expectEqual(interp.Value{ .int = 0 }, w.store.get(counter, &.{.{ .symbol = c }}).?[1]);
    // …and the watcher saw rule_failed in the same tick.
    try testing.expectEqual(interp.Value{ .int = 1 }, w.store.get(witness, &.{.{ .symbol = wsym }}).?[1]);
}

test "update to a missing row raises update_missed next tick" {
    const gpa = testing.allocator;
    var w = try World.init(gpa, 1);
    defer w.deinit();
    try genesis(&w,
        \\[
        \\ {"add_schema":{"name":"counter","fields":[["id","symbol"],["n","int"]],"key":1}},
        \\ {"add_schema":{"name":"witness","fields":[["id","symbol"],["n","int"]],"key":1}},
        \\ {"add_fact":{"schema":"witness","values":["w",0]}},
        \\ {"add_rule":{"name":"misser","on":"tick.start","when":{"lit":true},"do":[
        \\   {"update":{"schema":"counter","key":[{"lit":"ghost"}],"field":"n","op":"set","value":{"lit":1}}}
        \\ ]}},
        \\ {"add_rule":{"name":"watcher","on":"update_missed","when":{"lit":true},"do":[
        \\   {"update":{"schema":"witness","key":[{"lit":"w"}],"field":"n","op":"add","value":{"lit":1}}}
        \\ ]}}
        \\]
    );
    const witness = try w.interner.intern(gpa, "witness");
    const wsym = try w.interner.intern(gpa, "w");
    _ = try w.step();
    try testing.expectEqual(interp.Value{ .int = 0 }, w.store.get(witness, &.{.{ .symbol = wsym }}).?[1]);
    _ = try w.step();
    try testing.expectEqual(interp.Value{ .int = 1 }, w.store.get(witness, &.{.{ .symbol = wsym }}).?[1]);
}
