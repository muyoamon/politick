//! Kernel CLI: fold an event/diff log, run ticks, print the digest chain.
//!
//!   politick [--log <path>] [--ticks <n>] [--seed <n>]
//!
//! Creates the log with a format header if it does not exist. No LLM calls,
//! no network, no wall clock — the persona driver is a separate process.

const std = @import("std");
const Io = std.Io;
const politick = @import("politick");

const usage =
    \\usage: politick [--log <path>] [--ticks <n>] [--seed <n>]
    \\
    \\  --log    event/diff log path (default: world.ndjson)
    \\  --ticks  number of ticks to run (default: 10)
    \\  --seed   RNG seed (default: 42)
    \\
;

const Config = struct {
    log_path: []const u8 = "world.ndjson",
    ticks: u64 = 10,
    seed: u64 = 42,
};

const FlagError = error{ UnknownFlag, MissingValue, InvalidValue };

fn parseFlags(args: []const []const u8) FlagError!Config {
    var config: Config = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (i + 1 >= args.len) return error.MissingValue;
        i += 1;
        const val = args[i];
        if (std.mem.eql(u8, flag, "--log")) {
            config.log_path = val;
        } else if (std.mem.eql(u8, flag, "--ticks")) {
            config.ticks = std.fmt.parseInt(u64, val, 10) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, flag, "--seed")) {
            config.seed = std.fmt.parseInt(u64, val, 10) catch return error.InvalidValue;
        } else {
            return error.UnknownFlag;
        }
    }
    return config;
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    const config = parseFlags(args[1..]) catch {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    };

    const cwd = Io.Dir.cwd();
    const bytes = cwd.readFileAlloc(io, config.log_path, arena, .limited(1 << 30)) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const header = try politick.log.headerLine(arena);
            try cwd.writeFile(io, .{ .sub_path = config.log_path, .data = header });
            break :blk header;
        },
        else => return err,
    };

    // Validate the header and every entry envelope before running anything;
    // a malformed log must fail loudly, not fold silently.
    var it = politick.log.lines(bytes);
    const header_line = while (it.next()) |line| {
        if (line.len > 0) break line;
    } else {
        std.debug.print("error: log is empty (missing header)\n", .{});
        std.process.exit(1);
    };
    try politick.log.checkHeader(arena, header_line);

    var world = try politick.tick.World.init(arena, config.seed);
    var decoder = politick.ir.Decoder.init(world.irAllocator(), arena, &world.interner);

    var entry_count: u64 = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const entry = politick.log.parseEntry(arena, line) catch {
            std.debug.print("error: malformed log entry: {s}\n", .{line});
            std.process.exit(1);
        };
        defer entry.deinit(arena);
        switch (entry.envelope.kind) {
            .diff => {
                const ops = decoder.decodePayload(entry.payload) catch {
                    std.debug.print("error: bad IR in log entry seq {d}\n", .{entry.envelope.seq});
                    std.process.exit(1);
                };
                world.applyGenesis(ops) catch |err| {
                    std.debug.print("error: genesis apply failed at seq {d}: {t}\n", .{ entry.envelope.seq, err });
                    std.process.exit(1);
                };
            },
            // External events arrive with the persona driver (M4).
            .event => {
                std.debug.print("error: event entries are not supported yet (seq {d})\n", .{entry.envelope.seq});
                std.process.exit(1);
            },
        }
        entry_count += 1;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.print("log {s}: format ok, {d} entries\n", .{ config.log_path, entry_count });
    var last: politick.hash.Digest = world.chain;
    for (0..config.ticks) |_| {
        last = try world.step();
        try stdout.print("tick {d} {s}\n", .{ world.tick, politick.hash.hex(last) });
    }
    try stdout.print("run digest {s}\n", .{politick.hash.hex(last)});
    try stdout.flush();
}

test "flag parsing handles defaults, values, and errors" {
    const none = try parseFlags(&.{});
    try std.testing.expectEqualStrings("world.ndjson", none.log_path);
    try std.testing.expectEqual(@as(u64, 10), none.ticks);

    const some = try parseFlags(&.{ "--ticks", "100", "--seed", "7" });
    try std.testing.expectEqual(@as(u64, 100), some.ticks);
    try std.testing.expectEqual(@as(u64, 7), some.seed);

    try std.testing.expectError(error.UnknownFlag, parseFlags(&.{ "--bogus", "1" }));
    try std.testing.expectError(error.MissingValue, parseFlags(&.{"--ticks"}));
    try std.testing.expectError(error.InvalidValue, parseFlags(&.{ "--ticks", "abc" }));
}
