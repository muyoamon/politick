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

pub const Symbol = intern.Symbol;

const fuel_budget: u32 = 10_000;
/// Termination backstop for same-tick event cascades; events beyond this
/// are dropped deterministically.
const max_events_per_tick: usize = 10_000;

/// Kernel symbols are interned first, before any log content, so their ids
/// are stable across every world.
const KernelSyms = struct {
    tick_start: Symbol,
    tick_quarter: Symbol,
    rule_failed: Symbol,
    update_missed: Symbol,
    param: Symbol,
};

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
    rules_by_event: std.AutoArrayHashMapUnmanaged(Symbol, std.ArrayList(u32)) = .empty,
    /// Kernel events raised in APPLY (after ACT ended), delivered next tick.
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
        };
        return .{
            .gpa = gpa,
            .ir_arena = std.heap.ArenaAllocator.init(gpa),
            .interner = interner,
            .rng = std.Random.DefaultPrng.init(seed),
            .chain = h.finish(),
            .syms = syms,
        };
    }

    pub fn deinit(self: *World) void {
        self.interner.deinit(self.gpa);
        self.ir_arena.deinit();
    }

    /// Pre-tick-1 application of decoded diff ops, unconditionally — meta
    /// rule validation is M2. Ops must be allocated in this world's IR arena
    /// (decode with `irAllocator()`).
    pub fn applyGenesis(self: *World, ops: []const ir.DiffOp) !void {
        const arena = self.ir_arena.allocator();
        for (ops) |op| switch (op) {
            .add_schema => |schema| try self.store.addSchema(arena, schema),
            .add_rule => |rule| {
                const idx: u32 = @intCast(self.rules.items.len);
                try self.rules.append(arena, rule);
                const gop = try self.rules_by_event.getOrPut(arena, rule.on);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(arena, idx);
            },
            .add_fact => |fact| try self.store.insert(arena, fact.schema, fact.values),
        };
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
            const args = try self.ir_arena.allocator().dupe(interp.Value, &.{.{ .symbol = schema_sym }});
            try self.pending.append(self.ir_arena.allocator(), .{ .name = self.syms.update_missed, .args = args });
        }

        // Phase 3 COMMIT: no-op until diffs stage at runtime (M2).

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
    }

    fn stateHash(self: *World, scratch: std.mem.Allocator) !hash.Digest {
        var h = hash.StateHasher.init();
        try self.store.feedStateHash(scratch, &h);
        return h.finish();
    }
};

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
