//! Canonical state hashing — the test oracle for determinism. Every replay
//! test reduces to "same log + same seed ⇒ same hash sequence". All facts
//! must be fed in canonical (sorted) order; the hasher itself is just a
//! domain-separated SHA-256 with fixed-endian integer encoding.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Digest = [32]u8;

pub const StateHasher = struct {
    inner: Sha256,

    pub fn init() StateHasher {
        var h = StateHasher{ .inner = Sha256.init(.{}) };
        h.writeBytes("politick.state.v1");
        return h;
    }

    pub fn writeBytes(self: *StateHasher, bytes: []const u8) void {
        self.inner.update(bytes);
    }

    pub fn writeU8(self: *StateHasher, v: u8) void {
        self.inner.update(&[1]u8{v});
    }

    pub fn writeU32(self: *StateHasher, v: u32) void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, v, .little);
        self.inner.update(&buf);
    }

    pub fn writeU64(self: *StateHasher, v: u64) void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, v, .little);
        self.inner.update(&buf);
    }

    pub fn finish(self: *StateHasher) Digest {
        var out: Digest = undefined;
        self.inner.final(&out);
        return out;
    }
};

pub fn hex(digest: Digest) [64]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

test "hashing is stable and input-sensitive" {
    var h1 = StateHasher.init();
    h1.writeU64(42);
    var h2 = StateHasher.init();
    h2.writeU64(42);
    var h3 = StateHasher.init();
    h3.writeU64(43);

    const d1 = h1.finish();
    try std.testing.expectEqualSlices(u8, &d1, &h2.finish());
    try std.testing.expect(!std.mem.eql(u8, &d1, &h3.finish()));
}

test "integer encoding is width-tagged by caller, not ambiguous" {
    // writeU32(1) and writeU64(1) must differ: encodings are fixed-width.
    var h1 = StateHasher.init();
    h1.writeU32(1);
    var h2 = StateHasher.init();
    h2.writeU64(1);
    try std.testing.expect(!std.mem.eql(u8, &h1.finish(), &h2.finish()));
}
