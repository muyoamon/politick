//! The M2 exit-criteria suite: adversarial diffs against the COMMIT phase.
//! Each scenario seeds a world via genesis JSON, lets a rule stage a diff at
//! tick 4 (tick.quarter), and asserts the verdict through witness facts
//! (rules watching diff_committed / diff_rejected) or by direct kernel
//! inspection of the pending event queue.

const std = @import("std");
const testing = std.testing;
const ir = @import("ir.zig");
const tick = @import("tick.zig");
const interp = @import("interp.zig");

fn genesis(w: *tick.World, source: []const u8) !void {
    var decode_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer decode_arena.deinit();
    var decoder = ir.Decoder.init(w.irAllocator(), w.gpa, &w.interner);
    defer decoder.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, decode_arena.allocator(), source, .{});
    try w.applyGenesis(try decoder.decodePayload(parsed));
}

fn intFact(w: *tick.World, schema: []const u8, key: []const u8) !i64 {
    const s = try w.interner.intern(w.gpa, schema);
    const k = try w.interner.intern(w.gpa, key);
    const row = w.store.get(s, &.{.{ .symbol = k }}) orelse return error.MissingFact;
    return row[1].int;
}

/// Shared scaffolding: counter (mutated by committed statutes), witness
/// facts incremented by watcher rules on the kernel verdict events.
const scaffolding =
    \\ {"add_schema":{"name":"counter","fields":[["id","symbol"],["n","int"]],"key":1}},
    \\ {"add_fact":{"schema":"counter","values":["c",0]}},
    \\ {"add_schema":{"name":"committed_w","fields":[["id","symbol"],["n","int"]],"key":1}},
    \\ {"add_fact":{"schema":"committed_w","values":["w",0]}},
    \\ {"add_schema":{"name":"rejected_w","fields":[["id","symbol"],["n","int"]],"key":1}},
    \\ {"add_fact":{"schema":"rejected_w","values":["w",0]}},
    \\ {"add_rule":{"name":"on_committed","on":"diff_committed","when":{"lit":true},"do":[
    \\   {"update":{"schema":"committed_w","key":[{"lit":"w"}],"field":"n","op":"add","value":{"lit":1}}}
    \\ ]}},
    \\ {"add_rule":{"name":"on_rejected","on":"diff_rejected","when":{"lit":true},"do":[
    \\   {"update":{"schema":"rejected_w","key":[{"lit":"w"}],"field":"n","op":"add","value":{"lit":1}}}
    \\ ]}},
;

/// The statute most tests try to pass: adds a rule bumping the counter
/// every tick.
const subsidy_ops =
    \\[{"add_rule":{"name":"subsidy","on":"tick.start","when":{"lit":true},"do":[
    \\   {"update":{"schema":"counter","key":[{"lit":"c"}],"field":"n","op":"add","value":{"lit":1}}}
    \\ ]}}]
;

const allow_all_meta =
    \\ {"add_meta":{"name":"amend_statute","layer":"organic","governs":"statute","allow":{"lit":true}}},
;

/// Full genesis: scaffolding + scenario-specific terms + a propose rule
/// staging `ops` as diff "the_act" (by baron, via decree) at tick 4.
fn scenario(comptime extra: []const u8, comptime ops: []const u8) []const u8 {
    return "[" ++ scaffolding ++ extra ++
        \\ {"add_rule":{"name":"propose","on":"tick.quarter","when":{"lit":true},"do":[
        \\   {"stage":{"name":"the_act","by":"baron","via":"decree","ops":
    ++ ops ++
        \\   }}
        \\ ]}}
        \\]
    ;
}

test "valid statute commits atomically and its rule fires next tick" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w, scenario(allow_all_meta, subsidy_ops));

    for (0..6) |_| _ = try w.step();
    // Staged + committed tick 4; diff_committed seen tick 5; subsidy fires
    // ticks 5 and 6.
    try testing.expectEqual(@as(i64, 1), try intFact(&w, "committed_w", "w"));
    try testing.expectEqual(@as(i64, 0), try intFact(&w, "rejected_w", "w"));
    try testing.expectEqual(@as(i64, 2), try intFact(&w, "counter", "c"));
}

test "L0: a diff targeting the kernel-layer staged_diff schema is rejected" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w, scenario(allow_all_meta, "[{\"remove_schema\":\"staged_diff\"}]"));

    for (0..5) |_| _ = try w.step();
    try testing.expectEqual(@as(i64, 1), try intFact(&w, "rejected_w", "w"));
    try testing.expectEqual(@as(i64, 0), try intFact(&w, "committed_w", "w"));
    // The kernel schema survived.
    try testing.expect(w.store.schemas.contains(w.syms.staged_diff));
}

const population_consumer =
    \\ {"add_schema":{"name":"population","fields":[["bloc","symbol"],["count","int"]],"key":1}},
    \\ {"add_fact":{"schema":"population","values":["north",1000]}},
    \\ {"add_rule":{"name":"consumer","on":"never","when":{"lit":true},"do":[
    \\   {"foreach":{"schema":"population","bind":"p","do":[
    \\     {"update":{"schema":"counter","key":[{"lit":"c"}],"field":"n","op":"add","value":{"field":["p","count"]}}}
    \\   ]}}
    \\ ]}},
;

test "dangling reference: removing a schema a surviving rule uses is rejected with deps" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w, scenario(allow_all_meta ++ population_consumer, "[{\"remove_schema\":\"population\"}]"));

    for (0..4) |_| _ = try w.step();
    // Inspect the pending diff_rejected event directly for the dep list:
    // args = [diff name, reason, deps…].
    const consumer = try w.interner.intern(w.gpa, "consumer");
    var found = false;
    for (w.pending.items) |ev| {
        if (ev.name != w.syms.diff_rejected) continue;
        found = true;
        try testing.expectEqual(w.syms.r_dangling, ev.args[1].symbol);
        try testing.expectEqual(@as(usize, 3), ev.args.len);
        try testing.expectEqual(consumer, ev.args[2].symbol);
    }
    try testing.expect(found);
    try testing.expect(w.store.schemas.contains(try w.interner.intern(w.gpa, "population")));
}

test "revolutionary diff: removing schema and its dependents together commits" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w, scenario(
        allow_all_meta ++ population_consumer,
        "[{\"remove_rule\":\"consumer\"},{\"remove_schema\":\"population\"}]",
    ));

    for (0..5) |_| _ = try w.step();
    try testing.expectEqual(@as(i64, 1), try intFact(&w, "committed_w", "w"));
    try testing.expect(!w.store.schemas.contains(try w.interner.intern(w.gpa, "population")));
    // Consumer is gone; the two watchers and propose survive.
    try testing.expectEqual(@as(usize, 3), w.rules.items.len);
}

const office_meta =
    \\ {"add_schema":{"name":"office","fields":[["name","symbol"],["holder","symbol"]],"key":2}},
    \\ {"add_meta":{"name":"amend_statute","layer":"organic","governs":"statute",
    \\   "allow":{"exists":{"schema":"office","key":[{"lit":"tax_office"},{"field":["diff","by"]}]}}}},
;

test "capability escalation: staging without the required office fact is rejected" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w, scenario(office_meta, subsidy_ops));
    for (0..5) |_| _ = try w.step();
    try testing.expectEqual(@as(i64, 1), try intFact(&w, "rejected_w", "w"));
    try testing.expectEqual(@as(i64, 0), try intFact(&w, "committed_w", "w"));
}

test "capability check passes when diff.by holds the office" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w, scenario(office_meta ++
        \\ {"add_fact":{"schema":"office","values":["tax_office","baron"]}},
    , subsidy_ops));
    for (0..5) |_| _ = try w.step();
    try testing.expectEqual(@as(i64, 1), try intFact(&w, "committed_w", "w"));
}

test "self-weakening: removing the meta that governs statutes is judged by the organic layer's meta" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w, scenario(
        \\ {"add_meta":{"name":"amend_statute","layer":"organic","governs":"statute","allow":{"lit":true}}},
        \\ {"add_meta":{"name":"amend_organic","layer":"constitution","governs":"organic","allow":{"lit":false}}},
    , "[{\"remove_meta\":\"amend_statute\"}]"));

    for (0..5) |_| _ = try w.step();
    try testing.expectEqual(@as(i64, 1), try intFact(&w, "rejected_w", "w"));
    // The meta under attack survived.
    try testing.expectEqual(@as(usize, 2), w.metas.items.len);
}

test "default-deny: a layer with no governing meta rejects all diffs" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w, scenario("", subsidy_ops));

    for (0..5) |_| _ = try w.step();
    try testing.expectEqual(@as(i64, 1), try intFact(&w, "rejected_w", "w"));
    try testing.expectEqual(@as(i64, 0), try intFact(&w, "counter", "c"));
}

test "delay: min_staged_ticks holds the diff staged and visible as a fact" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w, scenario(
        \\ {"add_schema":{"name":"pending_w","fields":[["id","symbol"],["n","int"]],"key":1}},
        \\ {"add_fact":{"schema":"pending_w","values":["w",0]}},
        \\ {"add_meta":{"name":"amend_statute","layer":"organic","governs":"statute","min_staged_ticks":2,"allow":{"lit":true}}},
        \\ {"add_rule":{"name":"see_pending","on":"tick.start",
        \\   "when":{"exists":{"schema":"staged_diff","key":[{"lit":"the_act"}]}},"do":[
        \\   {"update":{"schema":"pending_w","key":[{"lit":"w"}],"field":"n","op":"add","value":{"lit":1}}}
        \\ ]}},
    , subsidy_ops));

    for (0..8) |_| _ = try w.step();
    // Staged tick 4; waits ticks 4 and 5; commits at tick 6's COMMIT.
    // The staged fact was visible during ACT of ticks 5 and 6.
    try testing.expectEqual(@as(i64, 2), try intFact(&w, "pending_w", "w"));
    // diff_committed seen tick 7.
    try testing.expectEqual(@as(i64, 1), try intFact(&w, "committed_w", "w"));
    // subsidy fired ticks 7 and 8.
    try testing.expectEqual(@as(i64, 2), try intFact(&w, "counter", "c"));
}

test "atomicity: a rejected diff leaves the state hash unchanged" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    // Default-deny: the staged diff is rejected within tick 4. Witness
    // rules only react at tick 5, so hashes after ticks 3 and 4 must match.
    try genesis(&w, scenario("", subsidy_ops));

    for (0..3) |_| _ = try w.step();
    const before = try w.stateHash(scratch.allocator());
    _ = try w.step(); // tick 4: stage, insert fact, reject, unstage
    const after = try w.stateHash(scratch.allocator());
    try testing.expectEqualSlices(u8, &before, &after);
}

test "determinism holds with staging and commits active" {
    var w1 = try tick.World.init(testing.allocator, 7);
    defer w1.deinit();
    var w2 = try tick.World.init(testing.allocator, 7);
    defer w2.deinit();
    const source = scenario(allow_all_meta, subsidy_ops);
    try genesis(&w1, source);
    try genesis(&w2, source);

    var last1: [32]u8 = undefined;
    var last2: [32]u8 = undefined;
    for (0..20) |_| {
        last1 = try w1.step();
        last2 = try w2.step();
    }
    try testing.expectEqualSlices(u8, &last1, &last2);
}
