//! The M4a suite: external log input (tick-addressed events and begins),
//! static validation via validateDiff with structured diagnostics, and
//! passivity of the tick report. The driver's whole kernel contract is
//! exercised here without any driver.

const std = @import("std");
const testing = std.testing;
const ir = @import("ir.zig");
const tick = @import("tick.zig");
const check = @import("check.zig");
const hash = @import("hash.zig");

fn genesis(w: *tick.World, source: []const u8) !void {
    var decode_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer decode_arena.deinit();
    var decoder = ir.Decoder.init(w.irAllocator(), w.gpa, &w.interner);
    defer decoder.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, decode_arena.allocator(), source, .{});
    try w.applyGenesis(try decoder.decodePayload(parsed));
}

fn decodeBegin(w: *tick.World, source: []const u8) !ir.Action.Begin {
    var decode_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer decode_arena.deinit();
    var decoder = ir.Decoder.init(w.irAllocator(), w.gpa, &w.interner);
    defer decoder.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, decode_arena.allocator(), source, .{});
    return decoder.decodeBeginObject(parsed);
}

fn decodeDiff(w: *tick.World, source: []const u8) !ir.Diff {
    var decode_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer decode_arena.deinit();
    var decoder = ir.Decoder.init(w.irAllocator(), w.gpa, &w.interner);
    defer decoder.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, decode_arena.allocator(), source, .{});
    return decoder.decodeDiffObject(parsed);
}

fn intFact(w: *tick.World, schema: []const u8, key: []const u8) !i64 {
    const s = try w.interner.intern(w.gpa, schema);
    const k = try w.interner.intern(w.gpa, key);
    const row = w.store.get(s, &.{.{ .symbol = k }}) orelse return error.MissingFact;
    return row[1].int;
}

test "external event is delivered at its tick, not before" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w,
        \\[
        \\ {"add_schema":{"name":"pcount","fields":[["id","symbol"],["n","int"]],"key":1}},
        \\ {"add_fact":{"schema":"pcount","values":["p",0]}},
        \\ {"add_rule":{"name":"petitioner","on":"petition","when":{"lit":true},"do":[
        \\   {"update":{"schema":"pcount","key":[{"lit":"p"}],"field":"n","op":"add","value":{"lit":1}}}
        \\ ]}}
        \\]
    );
    const petition = try w.interner.intern(w.gpa, "petition");

    _ = try w.step();
    try testing.expectEqual(@as(i64, 0), try intFact(&w, "pcount", "p"));

    // The main fold injects an entry addressed to tick N right before
    // stepping tick N — same shape here.
    try w.pendExternal(petition, &.{});
    _ = try w.step();
    try testing.expectEqual(@as(i64, 1), try intFact(&w, "pcount", "p"));

    _ = try w.step();
    try testing.expectEqual(@as(i64, 1), try intFact(&w, "pcount", "p"));
}

/// The pass_statute world from the M3 suite, minus the in-DSL sponsor —
/// the bill arrives from outside via beginExternal instead.
const legislature_world =
    \\[
    \\ {"add_schema":{"name":"counter","fields":[["id","symbol"],["n","int"]],"key":1}},
    \\ {"add_fact":{"schema":"counter","values":["c",0]}},
    \\ {"add_schema":{"name":"committed_w","fields":[["id","symbol"],["n","int"]],"key":1}},
    \\ {"add_fact":{"schema":"committed_w","values":["w",0]}},
    \\ {"add_schema":{"name":"abort_w","fields":[["id","symbol"],["n","int"]],"key":1}},
    \\ {"add_fact":{"schema":"abort_w","values":["w",0]}},
    \\ {"add_rule":{"name":"on_committed","on":"diff_committed","when":{"lit":true},"do":[
    \\   {"update":{"schema":"committed_w","key":[{"lit":"w"}],"field":"n","op":"add","value":{"lit":1}}}
    \\ ]}},
    \\ {"add_rule":{"name":"on_aborted","on":"procedure_aborted","when":{"lit":true},"do":[
    \\   {"update":{"schema":"abort_w","key":[{"lit":"w"}],"field":"n","op":"add","value":{"lit":1}}}
    \\ ]}},
    \\ {"add_meta":{"name":"amend_statute","layer":"organic","governs":"statute",
    \\   "allow":{"bin":["eq",{"field":["diff","via"]},{"lit":"pass_statute"}]}}},
    \\ {"add_meta":{"name":"amend_organic","layer":"constitution","governs":"organic","allow":{"lit":true}}},
    \\ {"add_schema":{"name":"seat","fields":[["holder","symbol"],["chamber","symbol"]],"key":2}},
    \\ {"add_fact":{"schema":"seat","values":["baron","lower"]}},
    \\ {"add_schema":{"name":"vote","fields":[["bill","symbol"],["yes","int"]],"key":1}},
    \\ {"add_fact":{"schema":"vote","values":["wool_act",0]}},
    \\ {"add_schema":{"name":"assent","fields":[["bill","symbol"],["given","boolean"]],"key":1}},
    \\ {"add_fact":{"schema":"assent","values":["wool_act",false]}},
    \\ {"add_procedure":{"name":"pass_statute","layer":"organic","steps":[
    \\   {"name":"introduce","requires":{"exists":{"schema":"seat","key":[{"field":["instance","by"]},{"lit":"lower"}]}}},
    \\   {"name":"floor_vote","requires":{"bin":["gt",{"lookup":{"schema":"vote","key":[{"field":["instance","id"]}],"field":"yes"}},{"lit":1}]}},
    \\   {"name":"assent","requires":{"lookup":{"schema":"assent","key":[{"field":["instance","id"]}],"field":"given"}}}
    \\ ]}},
    \\ {"add_rule":{"name":"voter","on":"procedure_advanced",
    \\   "when":{"bin":["eq",{"lookup":{"schema":"proc_instance","key":[{"lit":"wool_act"}],"field":"step"}},{"lit":"floor_vote"}]},"do":[
    \\   {"update":{"schema":"vote","key":[{"lit":"wool_act"}],"field":"yes","op":"add","value":{"lit":2}}}
    \\ ]}},
    \\ {"add_rule":{"name":"assenter","on":"procedure_advanced",
    \\   "when":{"bin":["eq",{"lookup":{"schema":"proc_instance","key":[{"lit":"wool_act"}],"field":"step"}},{"lit":"assent"}]},"do":[
    \\   {"update":{"schema":"assent","key":[{"lit":"wool_act"}],"field":"given","op":"set","value":{"lit":true}}}
    \\ ]}}
    \\]
;

const wool_act_begin =
    \\{"procedure":"pass_statute","bill":{"name":"wool_act","by":"baron","via":"pass_statute","ops":[
    \\  {"add_rule":{"name":"subsidy","on":"tick.start","when":{"lit":true},"do":[
    \\    {"update":{"schema":"counter","key":[{"lit":"c"}],"field":"n","op":"add","value":{"lit":1}}}
    \\  ]}}
    \\]}}
;

test "external begin drives pass_statute end to end from log input alone" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w, legislature_world);

    try w.beginExternal(try decodeBegin(&w, wool_act_begin));
    for (0..5) |_| _ = try w.step();
    // T1: begun, introduce satisfied, advance to floor_vote. T2: voter sees
    // the advance, votes, ADVANCE reaches assent. T3: assenter signs; final
    // step stages with via=pass_statute; amend_statute allows; committed.
    // T4, T5: subsidy fires.
    try testing.expectEqual(@as(i64, 1), try intFact(&w, "committed_w", "w"));
    try testing.expectEqual(@as(i64, 0), try intFact(&w, "abort_w", "w"));
    try testing.expectEqual(@as(i64, 2), try intFact(&w, "counter", "c"));
    try testing.expectEqual(@as(usize, 0), w.instances.items.len);
}

test "external begin naming a missing procedure aborts, never errors" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w, legislature_world);

    try w.beginExternal(try decodeBegin(&w,
        \\{"procedure":"no_such_procedure","bill":{"name":"wool_act","by":"baron","via":"pass_statute","ops":[]}}
    ));
    for (0..2) |_| _ = try w.step();
    try testing.expectEqual(@as(i64, 1), try intFact(&w, "abort_w", "w"));
    try testing.expectEqual(@as(usize, 0), w.instances.items.len);
}

test "validateDiff verdicts match COMMIT reasons and carry diagnostics" {
    var w = try tick.World.init(testing.allocator, 1);
    defer w.deinit();
    try genesis(&w, legislature_world);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ta = arena.allocator();

    // Valid statute: governed by amend_statute, no delay configured.
    const good = try decodeDiff(&w,
        \\{"name":"tax_act","by":"baron","via":"pass_statute","ops":[
        \\  {"add_rule":{"name":"tax","on":"tick.quarter","when":{"lit":true},"do":[
        \\    {"update":{"schema":"counter","key":[{"lit":"c"}],"field":"n","op":"add","value":{"lit":1}}}
        \\  ]}}
        \\]}
    );
    const ok = (try w.validateDiff(ta, &good, null)).ok;
    try testing.expectEqual(@as(u32, 0), ok.max_delay);
    try testing.expectEqual(@as(usize, 1), ok.touched_layers.len);

    // Dangling reference: diag pinpoints the unknown schema.
    var diag = check.Diag{};
    const dangling = try decodeDiff(&w,
        \\{"name":"ghost_act","by":"baron","via":"pass_statute","ops":[
        \\  {"add_rule":{"name":"ghost","on":"tick.start","when":{"exists":{"schema":"phantom","key":[{"lit":"x"}]}},"do":[]}}
        \\]}
    );
    const rej = (try w.validateDiff(ta, &dangling, &diag)).reject;
    try testing.expectEqual(w.syms.r_dangling, rej.reason);
    try testing.expectEqual(@as(usize, 1), rej.deps.len);
    try testing.expectEqualStrings("ghost", w.interner.lookup(rej.deps[0]));
    try testing.expectEqual(@as(?check.CheckError, error.UnknownSchema), diag.err);
    try testing.expectEqualStrings("phantom", w.interner.lookup(diag.symbol.?));

    // Unknown removal target.
    const unknown = try decodeDiff(&w,
        \\{"name":"rm_act","by":"baron","via":"pass_statute","ops":[{"remove_rule":"never_was"}]}
    );
    try testing.expectEqual(
        w.syms.r_unknown_target,
        (try w.validateDiff(ta, &unknown, null)).reject.reason,
    );

    // The Gödel boundary: kernel-layer targets are refused outright.
    const coup = try decodeDiff(&w,
        \\{"name":"coup","by":"baron","via":"pass_statute","ops":[{"remove_schema":"staged_diff"}]}
    );
    try testing.expectEqual(
        w.syms.r_l0,
        (try w.validateDiff(ta, &coup, null)).reject.reason,
    );

    // Ungoverned layer: default-deny.
    const lawless = try decodeDiff(&w,
        \\{"name":"lawless","by":"baron","via":"pass_statute","ops":[
        \\  {"add_rule":{"name":"free","on":"tick.start","layer":"wildlands","when":{"lit":true},"do":[]}}
        \\]}
    );
    try testing.expectEqual(
        w.syms.r_no_meta,
        (try w.validateDiff(ta, &lawless, null)).reject.reason,
    );
}

test "tick report is passive and external runs stay deterministic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // w1 runs with a report attached every tick, w2 bare; same external
    // schedule on both. Digests must agree tick for tick.
    var w1 = try tick.World.init(testing.allocator, 7);
    defer w1.deinit();
    var w2 = try tick.World.init(testing.allocator, 7);
    defer w2.deinit();
    try genesis(&w1, legislature_world);
    try genesis(&w2, legislature_world);
    try w1.beginExternal(try decodeBegin(&w1, wool_act_begin));
    try w2.beginExternal(try decodeBegin(&w2, wool_act_begin));

    const petition1 = try w1.interner.intern(w1.gpa, "petition");
    const petition2 = try w2.interner.intern(w2.gpa, "petition");
    var saw_commit = false;
    for (0..12) |i| {
        if (i == 5) {
            try w1.pendExternal(petition1, &.{.{ .int = 3 }});
            try w2.pendExternal(petition2, &.{.{ .int = 3 }});
        }
        var report = tick.TickReport{ .alloc = arena.allocator() };
        w1.report = &report;
        const d1 = try w1.step();
        w1.report = null;
        const d2 = try w2.step();
        try testing.expectEqualSlices(u8, &d1, &d2);
        for (report.commits.items) |c| {
            if (c.committed) saw_commit = true;
        }
    }
    try testing.expect(saw_commit);
}
