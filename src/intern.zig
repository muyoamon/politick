//! Symbol interning. Symbol ids are assigned in insertion order, so they are
//! deterministic as long as interning happens in log order — which makes
//! "canonical symbol order" (§9 of the design sketch) just integer order.

const std = @import("std");

pub const Symbol = enum(u32) {
    _,

    pub fn index(self: Symbol) u32 {
        return @intFromEnum(self);
    }
};

pub const Interner = struct {
    map: std.StringArrayHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *Interner, gpa: std.mem.Allocator) void {
        for (self.map.keys()) |key| gpa.free(key);
        self.map.deinit(gpa);
    }

    pub fn intern(self: *Interner, gpa: std.mem.Allocator, str: []const u8) !Symbol {
        const gop = try self.map.getOrPut(gpa, str);
        if (!gop.found_existing) {
            errdefer _ = self.map.pop();
            gop.key_ptr.* = try gpa.dupe(u8, str);
        }
        return @enumFromInt(@as(u32, @intCast(gop.index)));
    }

    pub fn lookup(self: *const Interner, sym: Symbol) []const u8 {
        return self.map.keys()[sym.index()];
    }

    pub fn count(self: *const Interner) u32 {
        return @intCast(self.map.count());
    }
};

test "interning is idempotent and ids are insertion-ordered" {
    const gpa = std.testing.allocator;
    var interner: Interner = .{};
    defer interner.deinit(gpa);

    const a = try interner.intern(gpa, "treasury");
    const b = try interner.intern(gpa, "seat");
    const a2 = try interner.intern(gpa, "treasury");

    try std.testing.expectEqual(a, a2);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(u32, 0), a.index());
    try std.testing.expectEqual(@as(u32, 1), b.index());
    try std.testing.expectEqualStrings("treasury", interner.lookup(a));
    try std.testing.expectEqualStrings("seat", interner.lookup(b));
    try std.testing.expectEqual(@as(u32, 2), interner.count());
}

test "interned key does not alias caller memory" {
    const gpa = std.testing.allocator;
    var interner: Interner = .{};
    defer interner.deinit(gpa);

    var buf = [_]u8{ 'm', 'o', 'o', 'd' };
    const sym = try interner.intern(gpa, &buf);
    buf[0] = 'X';
    try std.testing.expectEqualStrings("mood", interner.lookup(sym));
}
