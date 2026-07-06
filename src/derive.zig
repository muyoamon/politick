//! Derives — pure functions over committed facts. Hardcoded Zig behind a
//! pure interface for now; they migrate into the IR (and gain salsa-style
//! memoization) later, per dsl-sketch.md §11 "naive evaluation first".
//! Nothing here may mutate the store or observe queued updates.

const std = @import("std");
const store_mod = @import("store.zig");
const intern = @import("intern.zig");

pub fn totalPopulation(store: *const store_mod.FactStore, population: intern.Symbol) i64 {
    var total: i64 = 0;
    for (store.rows(population)) |row| {
        total += row[1].int;
    }
    return total;
}

test "totalPopulation sums the count field" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var interner: intern.Interner = .{};
    defer interner.deinit(gpa);
    var store: store_mod.FactStore = .{};

    const population = try interner.intern(gpa, "population");
    const ir = @import("ir.zig");
    try store.addSchema(a, .{ .name = population, .key_len = 1, .layer = try interner.intern(gpa, "statute"), .fields = try a.dupe(ir.Field, &.{
        .{ .name = try interner.intern(gpa, "bloc"), .ty = .symbol },
        .{ .name = try interner.intern(gpa, "count"), .ty = .int },
    }) });
    try store.insert(a, population, &.{ .{ .symbol = try interner.intern(gpa, "north") }, .{ .int = 1000 } });
    try store.insert(a, population, &.{ .{ .symbol = try interner.intern(gpa, "south") }, .{ .int = 800 } });

    try std.testing.expectEqual(@as(i64, 1800), totalPopulation(&store, population));
}
