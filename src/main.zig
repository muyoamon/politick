//! Kernel CLI: fold an event/diff log, run ticks, print the digest chain.
//!
//!   politick [--log <path>] [--ticks <n>] [--seed <n>] [--json]
//!   politick check --diff <file> [--log <path>] [--ticks <n>] [--seed <n>]
//!
//! Creates the log with a format header if it does not exist. No LLM calls,
//! no network, no wall clock — the persona driver is a separate process.

const std = @import("std");
const Io = std.Io;
const politick = @import("politick");

const usage =
    \\usage: politick [--log <path>] [--ticks <n>] [--seed <n>] [--json]
    \\       politick check --diff <file> [--log <path>] [--ticks <n>] [--seed <n>]
    \\
    \\  --log    event/diff log path (default: world.ndjson)
    \\  --ticks  number of ticks to run (default: 10; check: log extent)
    \\  --seed   RNG seed (default: 42)
    \\  --json   one NDJSON tick report per line on stdout (driver mode)
    \\  --diff   draft diff object (JSON file) to validate (check mode)
    \\
;

const Config = struct {
    log_path: []const u8 = "world.ndjson",
    ticks: ?u64 = null,
    seed: u64 = 42,
    json: bool = false,
    diff_path: ?[]const u8 = null,
};

const FlagError = error{ UnknownFlag, MissingValue, InvalidValue };

fn parseFlags(args: []const []const u8) FlagError!Config {
    var config: Config = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (std.mem.eql(u8, flag, "--json")) {
            config.json = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingValue;
        i += 1;
        const val = args[i];
        if (std.mem.eql(u8, flag, "--log")) {
            config.log_path = val;
        } else if (std.mem.eql(u8, flag, "--ticks")) {
            config.ticks = std.fmt.parseInt(u64, val, 10) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, flag, "--seed")) {
            config.seed = std.fmt.parseInt(u64, val, 10) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, flag, "--diff")) {
            config.diff_path = val;
        } else {
            return error.UnknownFlag;
        }
    }
    return config;
}

/// A tick-addressed external log entry, decoded up front and injected
/// before its tick steps.
const Scheduled = struct {
    tick: u64,
    payload: union(enum) {
        event: politick.ir.ExternalEvent,
        begin: politick.ir.Action.Begin,
    },
};

const Loaded = struct {
    entry_count: u64,
    max_entry_tick: u64,
    scheduled: []const Scheduled,
};

/// Read + header-check the log, apply genesis diffs, and decode the
/// tick-addressed externals (log order = deterministic interning order).
/// Malformed logs fail loudly.
fn loadLog(
    arena: std.mem.Allocator,
    io: Io,
    log_path: []const u8,
    world: *politick.tick.World,
    decoder: *politick.ir.Decoder,
) !Loaded {
    const cwd = Io.Dir.cwd();
    const bytes = cwd.readFileAlloc(io, log_path, arena, .limited(1 << 30)) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const header = try politick.log.headerLine(arena);
            try cwd.writeFile(io, .{ .sub_path = log_path, .data = header });
            break :blk header;
        },
        else => return err,
    };

    var it = politick.log.lines(bytes);
    const header_line = while (it.next()) |line| {
        if (line.len > 0) break line;
    } else {
        std.debug.print("error: log is empty (missing header)\n", .{});
        std.process.exit(1);
    };
    try politick.log.checkHeader(arena, header_line);

    var scheduled: std.ArrayList(Scheduled) = .empty;
    var entry_count: u64 = 0;
    var max_entry_tick: u64 = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const entry = politick.log.parseEntry(arena, line) catch {
            std.debug.print("error: malformed log entry: {s}\n", .{line});
            std.process.exit(1);
        };
        defer entry.deinit(arena);
        switch (entry.envelope.kind) {
            .diff => {
                // Bills travel via begin entries and commit through meta
                // validation; the unchecked genesis path is tick-0 only.
                if (entry.envelope.tick != 0) {
                    std.debug.print("error: diff entries are genesis (tick 0) only (seq {d})\n", .{entry.envelope.seq});
                    std.process.exit(1);
                }
                const ops = decoder.decodePayload(entry.payload) catch {
                    std.debug.print("error: bad IR in log entry seq {d}\n", .{entry.envelope.seq});
                    std.process.exit(1);
                };
                world.applyGenesis(ops) catch |err| {
                    std.debug.print("error: genesis apply failed at seq {d}: {t}\n", .{ entry.envelope.seq, err });
                    std.process.exit(1);
                };
            },
            .event, .begin => {
                if (entry.envelope.tick == 0) {
                    std.debug.print("error: external entries must target tick >= 1 (seq {d})\n", .{entry.envelope.seq});
                    std.process.exit(1);
                }
                const item = switch (entry.envelope.kind) {
                    .event => Scheduled{
                        .tick = entry.envelope.tick,
                        .payload = .{ .event = decoder.decodeEventObject(entry.payload) catch {
                            std.debug.print("error: bad event in log entry seq {d}\n", .{entry.envelope.seq});
                            std.process.exit(1);
                        } },
                    },
                    .begin => Scheduled{
                        .tick = entry.envelope.tick,
                        .payload = .{ .begin = decoder.decodeBeginObject(entry.payload) catch {
                            std.debug.print("error: bad begin in log entry seq {d}\n", .{entry.envelope.seq});
                            std.process.exit(1);
                        } },
                    },
                    .diff => unreachable,
                };
                try scheduled.append(arena, item);
                max_entry_tick = @max(max_entry_tick, entry.envelope.tick);
            },
        }
        entry_count += 1;
    }
    return .{
        .entry_count = entry_count,
        .max_entry_tick = max_entry_tick,
        .scheduled = scheduled.items,
    };
}

fn injectScheduled(world: *politick.tick.World, scheduled: []const Scheduled, next_tick: u64) !void {
    for (scheduled) |s| {
        if (s.tick != next_tick) continue;
        switch (s.payload) {
            .event => |ev| try world.pendExternal(ev.name, ev.args),
            .begin => |b| try world.beginExternal(b),
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    const is_check = args.len > 1 and std.mem.eql(u8, args[1], "check");
    const flag_args = if (is_check) args[2..] else args[1..];
    const config = parseFlags(flag_args) catch {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    };
    if (is_check and config.diff_path == null) {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    }

    var world = try politick.tick.World.init(arena, config.seed);
    var decoder = politick.ir.Decoder.init(world.irAllocator(), arena, &world.interner);
    const loaded = try loadLog(arena, io, config.log_path, &world, &decoder);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    if (is_check) {
        return runCheck(arena, io, config, &world, &decoder, loaded, stdout);
    }

    if (!config.json) {
        try stdout.print("log {s}: format ok, {d} entries\n", .{ config.log_path, loaded.entry_count });
    }
    // Run at least far enough to consume every scheduled entry.
    const run_ticks = @max(config.ticks orelse 10, loaded.max_entry_tick);
    var last: politick.hash.Digest = world.chain;
    for (0..run_ticks) |_| {
        try injectScheduled(&world, loaded.scheduled, world.tick + 1);
        var report = politick.tick.TickReport{ .alloc = arena };
        if (config.json) world.report = &report;
        last = try world.step();
        world.report = null;
        if (config.json) {
            try writeTickReport(stdout, &world, &report, last);
        } else {
            try stdout.print("tick {d} {s}\n", .{ world.tick, politick.hash.hex(last) });
        }
    }
    if (!config.json) {
        try stdout.print("run digest {s}\n", .{politick.hash.hex(last)});
    }
    try stdout.flush();
}

/// `politick check`: replay the log to its edge (or --ticks), then run
/// static validation (§9 passes 1–3) on a draft diff. Prints one JSON
/// verdict line; exit 0 = ok, 1 = rejected or undecodable draft.
fn runCheck(
    arena: std.mem.Allocator,
    io: Io,
    config: Config,
    world: *politick.tick.World,
    decoder: *politick.ir.Decoder,
    loaded: Loaded,
    stdout: *Io.Writer,
) !void {
    const run_ticks = @max(config.ticks orelse 0, loaded.max_entry_tick);
    for (0..run_ticks) |_| {
        try injectScheduled(world, loaded.scheduled, world.tick + 1);
        _ = try world.step();
    }

    const cwd = Io.Dir.cwd();
    const diff_bytes = cwd.readFileAlloc(io, config.diff_path.?, arena, .limited(1 << 20)) catch |err| {
        std.debug.print("error: cannot read diff file {s}: {t}\n", .{ config.diff_path.?, err });
        std.process.exit(2);
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, diff_bytes, .{}) catch {
        try stdout.writeAll("{\"ok\":false,\"reason\":\"bad_json\"}\n");
        try stdout.flush();
        std.process.exit(1);
    };
    const diff = decoder.decodeDiffObject(parsed) catch {
        try stdout.writeAll("{\"ok\":false,\"reason\":\"bad_ir\"}\n");
        try stdout.flush();
        std.process.exit(1);
    };

    var diag = politick.check.Diag{};
    switch (try world.validateDiff(arena, &diff, &diag)) {
        .ok => |o| {
            try stdout.print("{{\"ok\":true,\"min_staged_ticks\":{d},\"layers\":[", .{o.max_delay});
            for (o.touched_layers, 0..) |l, i| {
                if (i > 0) try stdout.writeByte(',');
                try writeJsonString(stdout, world.interner.lookup(l));
            }
            try stdout.writeAll("]}\n");
            try stdout.flush();
        },
        .reject => |r| {
            try stdout.writeAll("{\"ok\":false,\"reason\":");
            try writeJsonString(stdout, world.interner.lookup(r.reason));
            try stdout.writeAll(",\"deps\":[");
            for (r.deps, 0..) |d, i| {
                if (i > 0) try stdout.writeByte(',');
                try writeJsonString(stdout, world.interner.lookup(d));
            }
            try stdout.writeByte(']');
            if (diag.err) |e| {
                try stdout.writeAll(",\"diag\":{\"code\":");
                try writeJsonString(stdout, @errorName(e));
                if (diag.symbol) |s| {
                    try stdout.writeAll(",\"symbol\":");
                    try writeJsonString(stdout, world.interner.lookup(s));
                }
                if (diag.field) |f| {
                    try stdout.writeAll(",\"field\":");
                    try writeJsonString(stdout, world.interner.lookup(f));
                }
                try stdout.writeByte('}');
            }
            try stdout.writeAll("}\n");
            try stdout.flush();
            std.process.exit(1);
        },
    }
}

/// One NDJSON line per tick — the driver-facing output contract. Formatting
/// is hand-rolled like log.entryLine so the bytes are fully deterministic.
fn writeTickReport(
    w: *Io.Writer,
    world: *politick.tick.World,
    report: *const politick.tick.TickReport,
    digest: politick.hash.Digest,
) !void {
    const interner = &world.interner;
    try w.print("{{\"tick\":{d},\"digest\":\"{s}\",\"events\":[", .{ world.tick, politick.hash.hex(digest) });
    for (report.events.items, 0..) |ev, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try writeJsonString(w, interner.lookup(ev.name));
        try w.writeAll(",\"args\":[");
        for (ev.args, 0..) |a, j| {
            if (j > 0) try w.writeByte(',');
            try writeJsonValue(w, interner, a);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("],\"commits\":[");
    for (report.commits.items, 0..) |c, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"diff\":");
        try writeJsonString(w, interner.lookup(c.diff));
        if (c.committed) {
            try w.writeAll(",\"outcome\":\"committed\"}");
        } else {
            try w.writeAll(",\"outcome\":\"rejected\",\"reason\":");
            try writeJsonString(w, interner.lookup(c.reason.?));
            try w.writeAll(",\"deps\":[");
            for (c.deps, 0..) |d, j| {
                if (j > 0) try w.writeByte(',');
                try writeJsonString(w, interner.lookup(d));
            }
            try w.writeAll("]}");
        }
    }
    // Full fact dump (kernel-layer schemas included: staged_diff rows are
    // pending legislation, proc_instance rows are procedure positions —
    // exactly what a persona wants to see). Iteration order is insertion
    // order, deterministic per log.
    try w.writeAll("],\"facts\":{");
    for (world.store.schemas.keys(), 0..) |sym, i| {
        if (i > 0) try w.writeByte(',');
        const schema = world.store.schemas.get(sym).?;
        try writeJsonString(w, interner.lookup(sym));
        try w.writeAll(":{\"fields\":[");
        for (schema.fields, 0..) |f, j| {
            if (j > 0) try w.writeByte(',');
            try writeJsonString(w, interner.lookup(f.name));
        }
        try w.writeAll("],\"rows\":[");
        for (world.store.rows(sym), 0..) |row, j| {
            if (j > 0) try w.writeByte(',');
            try w.writeByte('[');
            for (row, 0..) |v, k| {
                if (k > 0) try w.writeByte(',');
                try writeJsonValue(w, interner, v);
            }
            try w.writeByte(']');
        }
        try w.writeAll("]}");
    }
    try w.writeAll("}}\n");
}

fn writeJsonValue(w: *Io.Writer, interner: *const politick.intern.Interner, v: politick.value.Value) !void {
    switch (v) {
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .symbol => |s| try writeJsonString(w, interner.lookup(s)),
    }
}

fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) {
            try w.print("\\u{x:0>4}", .{c});
        } else {
            try w.writeByte(c);
        },
    };
    try w.writeByte('"');
}

test "flag parsing handles defaults, values, and errors" {
    const none = try parseFlags(&.{});
    try std.testing.expectEqualStrings("world.ndjson", none.log_path);
    // Unset ticks resolve per mode: 10 for run, 0 for check.
    try std.testing.expectEqual(@as(?u64, null), none.ticks);
    try std.testing.expectEqual(@as(?[]const u8, null), none.diff_path);

    const some = try parseFlags(&.{ "--ticks", "100", "--seed", "7", "--json", "--diff", "bill.json" });
    try std.testing.expectEqual(@as(?u64, 100), some.ticks);
    try std.testing.expectEqualStrings("bill.json", some.diff_path.?);
    try std.testing.expectEqual(@as(u64, 7), some.seed);
    try std.testing.expect(some.json);
    try std.testing.expect(!none.json);

    try std.testing.expectError(error.UnknownFlag, parseFlags(&.{ "--bogus", "1" }));
    try std.testing.expectError(error.MissingValue, parseFlags(&.{"--ticks"}));
    try std.testing.expectError(error.InvalidValue, parseFlags(&.{ "--ticks", "abc" }));
}
