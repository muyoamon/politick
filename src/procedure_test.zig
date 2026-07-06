//! The M3 exit-criteria suite: the pass_statute procedure end to end.
//! A sponsor rule begins the procedure at tick 4 (tick.quarter); voter and
//! assenter rules react to procedure_advanced kernel events, gated on the
//! instance's current step via the proc_instance fact; witness facts record
//! the kernel verdict and abort events.

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

fn boolFact(w: *tick.World, schema: []const u8, key: []const u8) !bool {
    const s = try w.interner.intern(w.gpa, schema);
    const k = try w.interner.intern(w.gpa, key);
    const row = w.store.get(s, &.{.{ .symbol = k }}) orelse return error.MissingFact;
    return row[1].boolean;
}

fn instanceRowGone(w: *tick.World) !void {
    const id = try w.interner.intern(w.gpa, "wool_act");
    try testing.expectEqual(@as(usize, 0), w.instances.items.len);
    try testing.expect(w.store.get(w.syms.proc_instance, &.{.{ .symbol = id }}) == null);
}

/// Witness facts: counter (mutated by the committed bill), verdict watchers,
/// and an abort watcher on the procedure_aborted kernel event.
const witnesses =
    \\ {"add_schema":{"name":"counter","fields":[["id","symbol"],["n","int"]],"key":1}},
    \\ {"add_fact":{"schema":"counter","values":["c",0]}},
    \\ {"add_schema":{"name":"committed_w","fields":[["id","symbol"],["n","int"]],"key":1}},
    \\ {"add_fact":{"schema":"committed_w","values":["w",0]}},
    \\ {"add_schema":{"name":"rejected_w","fields":[["id","symbol"],["n","int"]],"key":1}},
    \\ {"add_fact":{"schema":"rejected_w","values":["w",0]}},
    \\ {"add_schema":{"name":"abort_w","fields":[["id","symbol"],["n","int"]],"key":1}},
    \\ {"add_fact":{"schema":"abort_w","values":["w",0]}},
    \\ {"add_rule":{"name":"on_committed","on":"diff_committed","when":{"lit":true},"do":[
    \\   {"update":{"schema":"committed_w","key":[{"lit":"w"}],"field":"n","op":"add","value":{"lit":1}}}
    \\ ]}},
    \\ {"add_rule":{"name":"on_rejected","on":"diff_rejected","when":{"lit":true},"do":[
    \\   {"update":{"schema":"rejected_w","key":[{"lit":"w"}],"field":"n","op":"add","value":{"lit":1}}}
    \\ ]}},
    \\ {"add_rule":{"name":"on_aborted","on":"procedure_aborted","when":{"lit":true},"do":[
    \\   {"update":{"schema":"abort_w","key":[{"lit":"w"}],"field":"n","op":"add","value":{"lit":1}}}
    \\ ]}},
;

/// Statutes must arrive via pass_statute (the forged-via guard makes the
/// `via` comparison trustworthy); organic law is freely amendable so the
/// mid-passage tests can legislate procedure changes.
const metas =
    \\ {"add_meta":{"name":"amend_statute","layer":"organic","governs":"statute",
    \\   "allow":{"bin":["eq",{"field":["diff","via"]},{"lit":"pass_statute"}]}}},
    \\ {"add_meta":{"name":"amend_organic","layer":"constitution","governs":"organic","allow":{"lit":true}}},
;

/// Chamber, tally, and assent state the procedure steps read.
const legislature =
    \\ {"add_schema":{"name":"seat","fields":[["holder","symbol"],["chamber","symbol"]],"key":2}},
    \\ {"add_fact":{"schema":"seat","values":["baron","lower"]}},
    \\ {"add_schema":{"name":"vote","fields":[["bill","symbol"],["yes","int"]],"key":1}},
    \\ {"add_fact":{"schema":"vote","values":["wool_act",0]}},
    \\ {"add_schema":{"name":"assent","fields":[["bill","symbol"],["given","boolean"]],"key":1}},
    \\ {"add_fact":{"schema":"assent","values":["wool_act",false]}},
;

const pass_statute =
    \\ {"add_procedure":{"name":"pass_statute","layer":"organic","steps":[
    \\   {"name":"introduce","requires":{"exists":{"schema":"seat","key":[{"field":["instance","by"]},{"lit":"lower"}]}}},
    \\   {"name":"floor_vote","requires":{"bin":["gt",{"lookup":{"schema":"vote","key":[{"field":["instance","id"]}],"field":"yes"}},{"lit":1}]}},
    \\   {"name":"assent","requires":{"lookup":{"schema":"assent","key":[{"field":["instance","id"]}],"field":"given"}}}
    \\ ]}},
;

/// Voter and assenter react to step transitions: procedure_advanced fires
/// the tick after an advance, when the proc_instance fact shows the new
/// current step — so each fires exactly once per passage.
const actors =
    \\ {"add_rule":{"name":"voter","on":"procedure_advanced",
    \\   "when":{"bin":["eq",{"lookup":{"schema":"proc_instance","key":[{"lit":"wool_act"}],"field":"step"}},{"lit":"floor_vote"}]},"do":[
    \\   {"update":{"schema":"vote","key":[{"lit":"wool_act"}],"field":"yes","op":"add","value":{"lit":2}}}
    \\ ]}},
    \\ {"add_rule":{"name":"assenter","on":"procedure_advanced",
    \\   "when":{"bin":["eq",{"lookup":{"schema":"proc_instance","key":[{"lit":"wool_act"}],"field":"step"}},{"lit":"assent"}]},"do":[
    \\   {"update":{"schema":"assent","key":[{"lit":"wool_act"}],"field":"given","op":"set","value":{"lit":true}}}
    \\ ]}},
;

/// One-shot sponsor: begins `proc` carrying the subsidy bill at the first
/// quarter, then flips its gate so later quarters don't restart the passage.
fn sponsor(comptime proc: []const u8) []const u8 {
    return
    \\ {"add_schema":{"name":"sponsor_gate","fields":[["id","symbol"],["done","boolean"]],"key":1}},
    \\ {"add_fact":{"schema":"sponsor_gate","values":["g",false]}},
    \\ {"add_rule":{"name":"sponsor","on":"tick.quarter",
    \\   "when":{"not":{"lookup":{"schema":"sponsor_gate","key":[{"lit":"g"}],"field":"done"}}},"do":[
    \\   {"begin":{"procedure":"
    ++ proc ++
    \\","bill":{"name":"wool_act","by":"baron","via":"pass_statute","ops":[
    \\     {"add_rule":{"name":"subsidy","on":"tick.start","when":{"lit":true},"do":[
    \\       {"update":{"schema":"counter","key":[{"lit":"c"}],"field":"n","op":"add","value":{"lit":1}}}
    \\     ]}}
    \\   ]}}},
    \\   {"update":{"schema":"sponsor_gate","key":[{"lit":"g"}],"field":"done","op":"set","value":{"lit":true}}}
    \\ ]}},
    ;
}

/// Every fragment ends with a trailing comma; drop the last one so the
/// array is valid JSON.
fn world(comptime extra: []const u8) []const u8 {
    const body = witnesses ++ metas ++ legislature ++ pass_statute ++ actors ++ extra;
    return "[" ++ body[0 .. body.len - 1] ++ "]";
}

const happy_path = world(sponsor("pass_statute"));

test "pass_statute end to end: introduced, voted, assented, staged, committed" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w, happy_path);

    for (0..8) |_| _ = try w.step();
    // T4: begun, introduce satisfied (seat exists), advance to floor_vote.
    // T5: voter sees the advance, votes; 2 > 1, advance to assent.
    // T6: assenter signs; final step satisfied — bill staged with
    //     via=pass_statute and committed the same tick's COMMIT.
    // T7, T8: subsidy fires.
    try testing.expectEqual(@as(i64, 1), try intFact(&w, "committed_w", "w"));
    try testing.expectEqual(@as(i64, 0), try intFact(&w, "rejected_w", "w"));
    try testing.expectEqual(@as(i64, 0), try intFact(&w, "abort_w", "w"));
    try testing.expectEqual(@as(i64, 2), try intFact(&w, "counter", "c"));
    try testing.expectEqual(true, try boolFact(&w, "assent", "wool_act"));
    try instanceRowGone(&w);
}

/// Replaces pass_statute mid-flight: same introduce/floor_vote, but the
/// last step becomes a royal seal instead of the assent.
const seal_reform =
    \\ {"add_schema":{"name":"seal","fields":[["bill","symbol"],["granted","boolean"]],"key":1}},
    \\ {"add_fact":{"schema":"seal","values":["wool_act",false]}},
    \\ {"add_rule":{"name":"sealer","on":"procedure_advanced",
    \\   "when":{"bin":["eq",{"lookup":{"schema":"proc_instance","key":[{"lit":"wool_act"}],"field":"step"}},{"lit":"royal_seal"}]},"do":[
    \\   {"update":{"schema":"seal","key":[{"lit":"wool_act"}],"field":"granted","op":"set","value":{"lit":true}}}
    \\ ]}},
    \\ {"add_rule":{"name":"reformer","on":"tick.quarter","when":{"lit":true},"do":[
    \\   {"stage":{"name":"reform_act","by":"chancellor","via":"decree","ops":[
    \\     {"remove_procedure":"pass_statute"},
    \\     {"add_procedure":{"name":"pass_statute","layer":"organic","steps":[
    \\       {"name":"introduce","requires":{"exists":{"schema":"seat","key":[{"field":["instance","by"]},{"lit":"lower"}]}}},
    \\       {"name":"floor_vote","requires":{"bin":["gt",{"lookup":{"schema":"vote","key":[{"field":["instance","id"]}],"field":"yes"}},{"lit":1}]}},
    \\       {"name":"royal_seal","requires":{"lookup":{"schema":"seal","key":[{"field":["instance","id"]}],"field":"granted"}}}
    \\     ]}}
    \\   ]}}
    \\ ]}},
;

test "mid-passage change affects remaining steps only" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w, world(sponsor("pass_statute") ++ seal_reform));

    for (0..8) |_| _ = try w.step();
    // T4: begun and advanced to floor_vote under the old definition; the
    // reform commits at T4's COMMIT (after ADVANCE). T5: voter votes; the
    // instance re-resolves to v2, matches floor_vote by name, advances to
    // royal_seal. T6: sealer grants; completes and commits. T7, T8: subsidy.
    try testing.expectEqual(@as(i64, 2), try intFact(&w, "committed_w", "w")); // reform + bill
    try testing.expectEqual(@as(i64, 0), try intFact(&w, "abort_w", "w"));
    try testing.expectEqual(@as(i64, 2), try intFact(&w, "counter", "c"));
    // The completed step stood; the replaced remainder never ran.
    try testing.expectEqual(false, try boolFact(&w, "assent", "wool_act"));
    try testing.expectEqual(true, try boolFact(&w, "seal", "wool_act"));
    try instanceRowGone(&w);
}

const vanish_reform =
    \\ {"add_rule":{"name":"reformer","on":"tick.quarter","when":{"lit":true},"do":[
    \\   {"stage":{"name":"reform_act","by":"chancellor","via":"decree","ops":[
    \\     {"remove_procedure":"pass_statute"},
    \\     {"add_procedure":{"name":"pass_statute","layer":"organic","steps":[
    \\       {"name":"petition","requires":{"lit":false}},
    \\       {"name":"decree","requires":{"lit":false}}
    \\     ]}}
    \\   ]}}
    \\ ]}},
;

test "current step vanishing from the new definition aborts the instance" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w, world(sponsor("pass_statute") ++ vanish_reform));

    for (0..6) |_| _ = try w.step();
    // T4: advance to floor_vote; reform commits. T5: re-resolve finds no
    // step named floor_vote — abort. T6: abort witnessed.
    try testing.expectEqual(@as(i64, 1), try intFact(&w, "abort_w", "w"));
    try testing.expectEqual(@as(i64, 1), try intFact(&w, "committed_w", "w")); // the reform
    try testing.expectEqual(@as(i64, 0), try intFact(&w, "counter", "c"));
    try instanceRowGone(&w);
}

const repeal_reform =
    \\ {"add_rule":{"name":"reformer","on":"tick.quarter","when":{"lit":true},"do":[
    \\   {"stage":{"name":"reform_act","by":"chancellor","via":"decree","ops":[
    \\     {"remove_procedure":"pass_statute"}
    \\   ]}}
    \\ ]}},
;

test "removing a procedure mid-flight aborts the instance with a kernel event" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w, world(sponsor("pass_statute") ++ repeal_reform));

    for (0..6) |_| _ = try w.step();
    // T4: advance to floor_vote; removal commits at T4's COMMIT. T5: the
    // next step re-resolves, finds nothing, aborts (§9). T6: witnessed.
    try testing.expectEqual(@as(i64, 1), try intFact(&w, "abort_w", "w"));
    try testing.expectEqual(@as(i64, 0), try intFact(&w, "counter", "c"));
    try testing.expectEqual(@as(usize, 0), w.procedures.items.len);
    try instanceRowGone(&w);
}

test "begin naming a missing procedure aborts immediately" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w, world(sponsor("no_such_procedure")));

    for (0..5) |_| _ = try w.step();
    try testing.expectEqual(@as(i64, 1), try intFact(&w, "abort_w", "w"));
    try testing.expectEqual(@as(i64, 0), try intFact(&w, "committed_w", "w"));
    try testing.expectEqual(@as(i64, 0), try intFact(&w, "rejected_w", "w"));
    try instanceRowGone(&w);
}

const forger =
    \\ {"add_rule":{"name":"forger","on":"tick.quarter","when":{"lit":true},"do":[
    \\   {"stage":{"name":"fake_act","by":"baron","via":"pass_statute","ops":[
    \\     {"add_rule":{"name":"subsidy","on":"tick.start","when":{"lit":true},"do":[
    \\       {"update":{"schema":"counter","key":[{"lit":"c"}],"field":"n","op":"add","value":{"lit":1}}}
    \\     ]}}
    \\   ]}}
    \\ ]}},
;

test "forged via: a rule-staged diff claiming a live procedure is rejected" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w, world(forger));

    for (0..4) |_| _ = try w.step();
    var found = false;
    for (w.pending.items) |ev| {
        if (ev.name != w.syms.diff_rejected) continue;
        found = true;
        try testing.expectEqual(w.syms.r_forged_via, ev.args[1].symbol);
    }
    try testing.expect(found);
    _ = try w.step();
    try testing.expectEqual(@as(i64, 1), try intFact(&w, "rejected_w", "w"));
    try testing.expectEqual(@as(i64, 0), try intFact(&w, "counter", "c"));
}

test "determinism holds with procedures in flight" {
    var w1 = try tick.World.init(testing.allocator, 7);
    defer w1.deinit();
    var w2 = try tick.World.init(testing.allocator, 7);
    defer w2.deinit();
    try genesis(&w1, happy_path);
    try genesis(&w2, happy_path);

    var last1: [32]u8 = undefined;
    var last2: [32]u8 = undefined;
    for (0..20) |_| {
        last1 = try w1.step();
        last2 = try w2.step();
    }
    try testing.expectEqualSlices(u8, &last1, &last2);
}
