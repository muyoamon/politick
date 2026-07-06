//! The append-only event/diff log — the source of truth. NDJSON: a header
//! line, then one entry per line. Envelope fields are written by hand so the
//! byte-level format is fully deterministic; payloads are opaque JSON,
//! written pre-serialized and parsed into std.json.Value (typed IR decoding
//! arrives with ir.zig).

const std = @import("std");

pub const format_version: u32 = 1;

pub const Kind = enum { event, diff };

pub const Envelope = struct {
    tick: u64,
    /// Monotonic per-log sequence id; doubles as the provenance timestamp
    /// for Phase-2 conflict resolution.
    seq: u64,
    kind: Kind,
};

pub const ParsedEntry = struct {
    envelope: Envelope,
    payload: std.json.Value,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: ParsedEntry, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self.arena);
    }
};

pub fn headerLine(gpa: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"format\":{d}}}\n", .{format_version});
}

pub const HeaderError = error{ MissingHeader, UnsupportedFormat, InvalidHeader };

pub fn checkHeader(gpa: std.mem.Allocator, line: []const u8) HeaderError!void {
    const parsed = std.json.parseFromSlice(struct { format: u32 }, gpa, line, .{}) catch
        return error.InvalidHeader;
    defer parsed.deinit();
    if (parsed.value.format != format_version) return error.UnsupportedFormat;
}

/// `payload` must be pre-serialized JSON; it is spliced in verbatim.
pub fn entryLine(gpa: std.mem.Allocator, envelope: Envelope, payload: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{{\"tick\":{d},\"seq\":{d},\"kind\":\"{s}\",\"payload\":{s}}}\n",
        .{ envelope.tick, envelope.seq, @tagName(envelope.kind), payload },
    );
}

pub fn parseEntry(gpa: std.mem.Allocator, line: []const u8) !ParsedEntry {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const Wire = struct { tick: u64, seq: u64, kind: Kind, payload: std.json.Value };
    const wire = try std.json.parseFromSliceLeaky(Wire, arena.allocator(), line, .{});
    return .{
        .envelope = .{ .tick = wire.tick, .seq = wire.seq, .kind = wire.kind },
        .payload = wire.payload,
        .arena = arena,
    };
}

/// Iterate NDJSON lines, skipping blank ones.
pub fn lines(bytes: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, bytes, '\n');
}

test "header round-trips and rejects wrong versions" {
    const gpa = std.testing.allocator;
    const header = try headerLine(gpa);
    defer gpa.free(header);
    try checkHeader(gpa, std.mem.trimEnd(u8, header, "\n"));
    try std.testing.expectError(error.UnsupportedFormat, checkHeader(gpa, "{\"format\":999}"));
    try std.testing.expectError(error.InvalidHeader, checkHeader(gpa, "not json"));
}

test "entry round-trips through write and parse" {
    const gpa = std.testing.allocator;
    const line = try entryLine(gpa, .{ .tick = 7, .seq = 42, .kind = .event }, "{\"name\":\"levy\",\"amount\":3}");
    defer gpa.free(line);

    const entry = try parseEntry(gpa, std.mem.trimEnd(u8, line, "\n"));
    defer entry.deinit(gpa);

    try std.testing.expectEqual(@as(u64, 7), entry.envelope.tick);
    try std.testing.expectEqual(@as(u64, 42), entry.envelope.seq);
    try std.testing.expectEqual(Kind.event, entry.envelope.kind);
    try std.testing.expectEqualStrings("levy", entry.payload.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 3), entry.payload.object.get("amount").?.integer);
}
