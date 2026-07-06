//! The M1 exit-criteria test: the poll-tax world (dsl-sketch.md §2.3),
//! seeded as IR from the embedded log, runs 100 ticks. Semantic assertions
//! catch logic drift; the golden digest catches any determinism break —
//! if it changes, either the state hash definition changed on purpose
//! (update the constant and say so in the commit) or determinism broke.

const std = @import("std");
const log = @import("log.zig");
const ir = @import("ir.zig");
const tick = @import("tick.zig");
const hash = @import("hash.zig");
const value_mod = @import("value.zig");

const poll_tax_log = @embedFile("testdata/poll_tax.ndjson");

/// Paste-updated from a verified run; see file doc comment.
/// M2 change: the state hash grew to cover schema identity (layer, fields),
/// rule/meta term identities, and the kernel staged_diff schema.
/// M3 change: new kernel syms shifted symbol ids, the kernel proc_instance
/// schema joined the fact hash, and procedure identities joined the state
/// hash ("procedures.v1" section).
const golden_digest = "34bca2c4b722dc876181350cffc13777c69bd860f8aa89700463faefd51340de";

test "poll tax world: 100 ticks, semantic drift, golden digest" {
    const gpa = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    var world = try tick.World.init(gpa, 42);
    defer world.deinit();
    var decoder = ir.Decoder.init(world.irAllocator(), gpa, &world.interner);
    defer decoder.deinit();

    var it = log.lines(poll_tax_log);
    const header = it.next().?;
    try log.checkHeader(gpa, header);
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const entry = try log.parseEntry(gpa, line);
        defer entry.deinit(gpa);
        try std.testing.expectEqual(log.Kind.diff, entry.envelope.kind);
        try world.applyGenesis(try decoder.decodePayload(entry.payload));
    }

    var last: hash.Digest = undefined;
    for (0..100) |_| last = try world.step();

    // 25 quarters fired: approval drops 0.01 per quarter, treasury gains
    // (1000 + 800) * 0.1 per quarter.
    const north = try world.interner.intern(gpa, "north");
    const approval = try world.interner.intern(gpa, "approval");
    const treasury = try world.interner.intern(gpa, "treasury");
    const main_t = try world.interner.intern(gpa, "main");

    const approval_north = world.store.get(approval, &.{.{ .symbol = north }}).?[1].float;
    const treasury_amount = world.store.get(treasury, &.{.{ .symbol = main_t }}).?[1].float;
    try std.testing.expectApproxEqAbs(@as(f64, 0.35), approval_north, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4500.0), treasury_amount, 1e-9);

    try std.testing.expectEqualStrings(golden_digest, &hash.hex(last));
}
