//! Runtime fact values. Fact schemas are runtime data (legislatable), so
//! values are a tagged union checked against schema facts by the kernel,
//! not by the Zig type system.

const std = @import("std");
const intern = @import("intern.zig");
const hash = @import("hash.zig");

pub const Value = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    symbol: intern.Symbol,

    /// Total order used for canonical sorting: tag first, then payload.
    /// NaN floats must be rejected at validation; they have no total order.
    pub fn order(a: Value, b: Value) std.math.Order {
        const tag_order = std.math.order(@intFromEnum(a), @intFromEnum(b));
        if (tag_order != .eq) return tag_order;
        return switch (a) {
            .int => |v| std.math.order(v, b.int),
            .float => |v| std.math.order(v, b.float),
            .boolean => |v| std.math.order(@intFromBool(v), @intFromBool(b.boolean)),
            .symbol => |v| std.math.order(v.index(), b.symbol.index()),
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        return a.order(b) == .eq;
    }

    /// Canonical byte encoding for state hashing: tag byte, then
    /// little-endian payload. Floats hash by bit pattern.
    pub fn feed(self: Value, hasher: *hash.StateHasher) void {
        hasher.writeU8(@intFromEnum(self));
        switch (self) {
            .int => |v| hasher.writeU64(@bitCast(v)),
            .float => |v| hasher.writeU64(@bitCast(v)),
            .boolean => |v| hasher.writeU8(@intFromBool(v)),
            .symbol => |v| hasher.writeU32(v.index()),
        }
    }
};

test "order is a total order across tags and payloads" {
    const a = Value{ .int = 3 };
    const b = Value{ .int = 5 };
    const c = Value{ .float = 0.5 };

    try std.testing.expectEqual(std.math.Order.lt, a.order(b));
    try std.testing.expectEqual(std.math.Order.gt, b.order(a));
    try std.testing.expectEqual(std.math.Order.eq, a.order(a));
    // Cross-tag: int tag sorts before float tag regardless of magnitude.
    try std.testing.expectEqual(std.math.Order.lt, b.order(c));
}

test "distinct values feed distinct canonical bytes" {
    var h1 = hash.StateHasher.init();
    var h2 = hash.StateHasher.init();
    (Value{ .int = 1 }).feed(&h1);
    (Value{ .boolean = true }).feed(&h2);
    try std.testing.expect(!std.mem.eql(u8, &h1.finish(), &h2.finish()));
}
