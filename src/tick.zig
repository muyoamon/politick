//! The kernel tick loop: READ → ACT → APPLY → COMMIT. The phases are stubs
//! until the fact store and rule interpreter land (slice 1), but the loop,
//! the per-tick arena, the seeded RNG, and the chained run digest are the
//! permanent shape.

const std = @import("std");
const intern = @import("intern.zig");
const hash = @import("hash.zig");

pub const World = struct {
    gpa: std.mem.Allocator,
    interner: intern.Interner = .{},
    rng: std.Random.DefaultPrng,
    tick: u64 = 0,
    /// Chained digest: H(prev chain, tick, state hash). A run's identity.
    chain: hash.Digest,

    pub fn init(gpa: std.mem.Allocator, seed: u64) World {
        var h = hash.StateHasher.init();
        h.writeBytes("politick.chain.v1");
        return .{
            .gpa = gpa,
            .rng = std.Random.DefaultPrng.init(seed),
            .chain = h.finish(),
        };
    }

    pub fn deinit(self: *World) void {
        self.interner.deinit(self.gpa);
    }

    /// Run one tick; returns the new chain digest.
    pub fn step(self: *World) !hash.Digest {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();

        self.phaseRead();
        self.phaseAct(arena.allocator());
        self.phaseApply();
        self.phaseCommit();

        self.tick += 1;
        var h = hash.StateHasher.init();
        h.writeBytes("politick.chain.v1");
        h.writeBytes(&self.chain);
        h.writeU64(self.tick);
        const state = self.stateHash();
        h.writeBytes(&state);
        self.chain = h.finish();
        return self.chain;
    }

    /// Hash of committed facts in canonical order. Empty until the fact
    /// store lands.
    fn stateHash(self: *World) hash.Digest {
        _ = self;
        var h = hash.StateHasher.init();
        return h.finish();
    }

    fn phaseRead(self: *World) void {
        // Derives recompute from committed facts.
        _ = self;
    }

    fn phaseAct(self: *World, tick_arena: std.mem.Allocator) void {
        // Actor policies run; rules fire on events; actions queue in the
        // tick arena.
        _ = self;
        _ = tick_arena;
    }

    fn phaseApply(self: *World) void {
        // Queued fact updates apply; conflicts resolve by priority, then
        // provenance seq.
        _ = self;
    }

    fn phaseCommit(self: *World) void {
        // Staged diffs validate against meta rules and commit atomically.
        _ = self;
    }
};

test "same seed and tick count reproduce the chain digest" {
    const gpa = std.testing.allocator;

    var w1 = World.init(gpa, 42);
    defer w1.deinit();
    var w2 = World.init(gpa, 42);
    defer w2.deinit();

    var last1: hash.Digest = undefined;
    var last2: hash.Digest = undefined;
    for (0..100) |_| {
        last1 = try w1.step();
        last2 = try w2.step();
    }
    try std.testing.expectEqualSlices(u8, &last1, &last2);
}

test "chain digest distinguishes tick counts" {
    const gpa = std.testing.allocator;
    var w = World.init(gpa, 42);
    defer w.deinit();
    const d1 = try w.step();
    const d2 = try w.step();
    try std.testing.expect(!std.mem.eql(u8, &d1, &d2));
}
