//! The fact store. Phase discipline is enforced by API shape: reads any
//! time, mutation only via `insert` (genesis) and the queue/apply pair —
//! updates queue during ACT and land in APPLY, so a rule can never observe
//! its own writes. Rows live in the world's IR arena; allocators are passed
//! per call because World moves by value and must not store arena pointers.

const std = @import("std");
const ir = @import("ir.zig");
const value_mod = @import("value.zig");
const hash = @import("hash.zig");

pub const Symbol = ir.Symbol;
pub const Value = value_mod.Value;

pub const QueuedUpdate = struct {
    schema: Symbol,
    /// Owned by the tick arena; applied before the arena resets.
    key: []const Value,
    field_index: usize,
    op: ir.UpdateOp,
    value: Value,
    priority: i32,
    /// Provenance timestamp: ties in priority resolve by seq.
    seq: u64,
};

pub const StoreError = error{
    DuplicateSchema,
    UnknownSchema,
    UnknownField,
    ArityMismatch,
    TypeMismatch,
    KeyFieldUpdate,
    OutOfMemory,
};

const Table = struct {
    rows: std.ArrayList([]Value) = .empty,
};

pub const FactStore = struct {
    schemas: std.AutoArrayHashMapUnmanaged(Symbol, ir.Schema) = .empty,
    tables: std.AutoArrayHashMapUnmanaged(Symbol, Table) = .empty,
    queued: std.ArrayList(QueuedUpdate) = .empty,

    pub fn addSchema(self: *FactStore, arena: std.mem.Allocator, schema: ir.Schema) StoreError!void {
        if (self.schemas.contains(schema.name)) return error.DuplicateSchema;
        self.schemas.put(arena, schema.name, schema) catch return error.OutOfMemory;
        self.tables.put(arena, schema.name, .{}) catch return error.OutOfMemory;
    }

    /// Genesis-only mutation path. Duplicate key replaces the row (upsert).
    pub fn insert(self: *FactStore, arena: std.mem.Allocator, schema_sym: Symbol, values: []const Value) StoreError!void {
        const schema = self.schemas.get(schema_sym) orelse return error.UnknownSchema;
        if (values.len != schema.fields.len) return error.ArityMismatch;

        const row = arena.alloc(Value, values.len) catch return error.OutOfMemory;
        for (values, schema.fields, 0..) |v, f, i| {
            row[i] = try coerce(f.ty, v);
        }

        const table = self.tables.getPtr(schema_sym).?;
        if (findRow(schema, table.rows.items, row[0..schema.key_len])) |existing| {
            @memcpy(existing, row);
        } else {
            table.rows.append(arena, row) catch return error.OutOfMemory;
        }
    }

    /// COMMIT-only (§9 cascade). Returns the number of dropped rows for the
    /// facts_dropped event. Removing an absent schema is a no-op returning 0
    /// (callers validate existence beforehand).
    pub fn removeSchema(self: *FactStore, name: Symbol) usize {
        const table = self.tables.getPtr(name) orelse return 0;
        const count = table.rows.items.len;
        _ = self.tables.orderedRemove(name);
        _ = self.schemas.orderedRemove(name);
        return count;
    }

    /// COMMIT-only. Returns whether a row was removed.
    pub fn removeFact(self: *FactStore, schema_sym: Symbol, key: []const Value) bool {
        const schema = self.schemas.get(schema_sym) orelse return false;
        const table = self.tables.getPtr(schema_sym) orelse return false;
        const idx = findRowIndex(schema, table.rows.items, key) orelse return false;
        _ = table.rows.orderedRemove(idx);
        return true;
    }

    pub fn get(self: *const FactStore, schema_sym: Symbol, key: []const Value) ?[]const Value {
        const schema = self.schemas.get(schema_sym) orelse return null;
        const table = self.tables.get(schema_sym) orelse return null;
        return findRow(schema, table.rows.items, key);
    }

    pub fn rows(self: *const FactStore, schema_sym: Symbol) []const []Value {
        const table = self.tables.get(schema_sym) orelse return &.{};
        return table.rows.items;
    }

    /// Validates an update at staging time so a bad update fails its rule
    /// atomically; returns the field index and the value coerced to the
    /// field type. Key fields are immutable (rows are addressed by key).
    pub fn validateUpdate(
        self: *const FactStore,
        schema_sym: Symbol,
        field: Symbol,
        val: Value,
    ) StoreError!struct { field_index: usize, value: Value } {
        const schema = self.schemas.get(schema_sym) orelse return error.UnknownSchema;
        const fi = schema.fieldIndex(field) orelse return error.UnknownField;
        if (fi < schema.key_len) return error.KeyFieldUpdate;
        return .{ .field_index = fi, .value = try coerce(schema.fields[fi].ty, val) };
    }

    pub fn queueUpdate(self: *FactStore, arena: std.mem.Allocator, update: QueuedUpdate) StoreError!void {
        self.queued.append(arena, update) catch return error.OutOfMemory;
    }

    /// Phase 2. Applies queued updates in (priority, seq) order — total
    /// because seq is unique. Updates addressing a missing row are skipped
    /// and reported via `missed` (delivered as kernel events next tick);
    /// apply itself never fails.
    pub fn applyQueued(self: *FactStore, scratch: std.mem.Allocator, missed: *std.ArrayList(Symbol)) error{OutOfMemory}!void {
        std.mem.sort(QueuedUpdate, self.queued.items, {}, updateLessThan);
        for (self.queued.items) |u| {
            const schema = self.schemas.get(u.schema).?;
            const table = self.tables.getPtr(u.schema).?;
            const row = findRow(schema, table.rows.items, u.key) orelse {
                missed.append(scratch, u.schema) catch return error.OutOfMemory;
                continue;
            };
            switch (u.op) {
                .set => row[u.field_index] = u.value,
                .add => switch (row[u.field_index]) {
                    .int => |v| row[u.field_index] = .{ .int = v + u.value.int },
                    .float => |v| row[u.field_index] = .{ .float = v + u.value.float },
                    else => unreachable, // validateUpdate coerced to a numeric field type
                },
            }
        }
        self.queued.clearRetainingCapacity();
    }

    /// Canonical state hash: schemas in symbol order — identity (layer,
    /// key_len, fields) plus rows in key order (keys are unique, so this is
    /// a total order), length-prefixed.
    pub fn feedStateHash(self: *const FactStore, scratch: std.mem.Allocator, hasher: *hash.StateHasher) error{OutOfMemory}!void {
        const schema_syms = try scratch.dupe(Symbol, self.schemas.keys());
        std.mem.sort(Symbol, schema_syms, {}, symbolLessThan);

        for (schema_syms) |sym| {
            const schema = self.schemas.get(sym).?;
            const table = self.tables.get(sym).?;
            hasher.writeU32(sym.index());
            hasher.writeU32(schema.layer.index());
            hasher.writeU8(schema.key_len);
            hasher.writeU64(schema.fields.len);
            for (schema.fields) |f| {
                hasher.writeU32(f.name.index());
                hasher.writeU8(@intFromEnum(f.ty));
            }
            hasher.writeU64(table.rows.items.len);

            const sorted = try scratch.dupe([]Value, table.rows.items);
            std.mem.sort([]Value, sorted, schema, rowLessThan);
            for (sorted) |row| {
                for (row) |v| v.feed(hasher);
            }
        }
    }
};

pub fn coerce(ty: ir.FieldType, v: Value) StoreError!Value {
    return switch (ty) {
        .int => if (v == .int) v else error.TypeMismatch,
        .float => switch (v) {
            .float => v,
            .int => |i| .{ .float = @floatFromInt(i) },
            else => error.TypeMismatch,
        },
        .boolean => if (v == .boolean) v else error.TypeMismatch,
        .symbol => if (v == .symbol) v else error.TypeMismatch,
    };
}

fn findRow(schema: ir.Schema, table_rows: []const []Value, key: []const Value) ?[]Value {
    const idx = findRowIndex(schema, table_rows, key) orelse return null;
    return table_rows[idx];
}

fn findRowIndex(schema: ir.Schema, table_rows: []const []Value, key: []const Value) ?usize {
    if (key.len != schema.key_len) return null;
    outer: for (table_rows, 0..) |row, i| {
        for (key, row[0..schema.key_len]) |k, r| {
            if (!k.eql(r)) continue :outer;
        }
        return i;
    }
    return null;
}

fn updateLessThan(_: void, a: QueuedUpdate, b: QueuedUpdate) bool {
    if (a.priority != b.priority) return a.priority < b.priority;
    return a.seq < b.seq;
}

fn symbolLessThan(_: void, a: Symbol, b: Symbol) bool {
    return a.index() < b.index();
}

fn rowLessThan(schema: ir.Schema, a: []Value, b: []Value) bool {
    for (a[0..schema.key_len], b[0..schema.key_len]) |av, bv| {
        switch (av.order(bv)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
    }
    return false;
}

const testing = std.testing;
const intern = @import("intern.zig");

const TestWorld = struct {
    arena: std.heap.ArenaAllocator,
    interner: intern.Interner = .{},
    store: FactStore = .{},

    fn init() TestWorld {
        return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(self: *TestWorld) void {
        self.interner.deinit(testing.allocator);
        self.arena.deinit();
    }

    fn sym(self: *TestWorld, s: []const u8) !Symbol {
        return self.interner.intern(testing.allocator, s);
    }

    /// approval(bloc*: symbol, value: float)
    fn addApproval(self: *TestWorld) !Symbol {
        const a = self.arena.allocator();
        const fields = try a.dupe(ir.Field, &.{
            .{ .name = try self.sym("bloc"), .ty = .symbol },
            .{ .name = try self.sym("value"), .ty = .float },
        });
        const name = try self.sym("approval");
        try self.store.addSchema(a, .{ .name = name, .fields = fields, .key_len = 1, .layer = try self.sym("statute") });
        return name;
    }
};

test "removeSchema drops rows, removeFact drops one row" {
    var t = TestWorld.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const approval = try t.addApproval();
    const north = try t.sym("north");
    const south = try t.sym("south");
    try t.store.insert(a, approval, &.{ .{ .symbol = north }, .{ .float = 0.6 } });
    try t.store.insert(a, approval, &.{ .{ .symbol = south }, .{ .float = 0.5 } });

    try testing.expect(t.store.removeFact(approval, &.{.{ .symbol = north }}));
    try testing.expect(!t.store.removeFact(approval, &.{.{ .symbol = north }}));
    try testing.expectEqual(@as(usize, 1), t.store.rows(approval).len);

    try testing.expectEqual(@as(usize, 1), t.store.removeSchema(approval));
    try testing.expectEqual(@as(?ir.Schema, null), t.store.schemas.get(approval));
    try testing.expectEqual(@as(usize, 0), t.store.removeSchema(approval));
}

test "insert validates arity and type, upserts by key" {
    var t = TestWorld.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const approval = try t.addApproval();
    const north = try t.sym("north");

    try testing.expectError(error.ArityMismatch, t.store.insert(a, approval, &.{.{ .symbol = north }}));
    try testing.expectError(error.TypeMismatch, t.store.insert(a, approval, &.{ .{ .int = 1 }, .{ .float = 0.5 } }));

    try t.store.insert(a, approval, &.{ .{ .symbol = north }, .{ .float = 0.6 } });
    try t.store.insert(a, approval, &.{ .{ .symbol = north }, .{ .float = 0.4 } });
    try testing.expectEqual(@as(usize, 1), t.store.rows(approval).len);
    try testing.expectEqual(Value{ .float = 0.4 }, t.store.get(approval, &.{.{ .symbol = north }}).?[1]);

    // int coerces into a float field
    try t.store.insert(a, approval, &.{ .{ .symbol = try t.sym("south") }, .{ .int = 1 } });
    try testing.expectEqual(Value{ .float = 1.0 }, t.store.get(approval, &.{.{ .symbol = try t.sym("south") }}).?[1]);
}

test "applyQueued resolves conflicts by priority then seq, reports misses" {
    var t = TestWorld.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const approval = try t.addApproval();
    const north = try t.sym("north");
    const key = try a.dupe(Value, &.{.{ .symbol = north }});
    try t.store.insert(a, approval, &.{ .{ .symbol = north }, .{ .float = 0.0 } });

    const vu = try t.store.validateUpdate(approval, try t.sym("value"), .{ .float = 1.0 });
    // Higher priority queued first, lower priority later: sort order must
    // make the higher-priority write land last.
    try t.store.queueUpdate(a, .{ .schema = approval, .key = key, .field_index = vu.field_index, .op = .set, .value = .{ .float = 9.0 }, .priority = 5, .seq = 1 });
    try t.store.queueUpdate(a, .{ .schema = approval, .key = key, .field_index = vu.field_index, .op = .set, .value = .{ .float = 1.0 }, .priority = 0, .seq = 2 });
    // Miss: unknown key
    const ghost_key = try a.dupe(Value, &.{.{ .symbol = try t.sym("ghost") }});
    try t.store.queueUpdate(a, .{ .schema = approval, .key = ghost_key, .field_index = vu.field_index, .op = .set, .value = .{ .float = 1.0 }, .priority = 0, .seq = 3 });

    var missed: std.ArrayList(Symbol) = .empty;
    try t.store.applyQueued(a, &missed);
    try testing.expectEqual(Value{ .float = 9.0 }, t.store.get(approval, &.{.{ .symbol = north }}).?[1]);
    try testing.expectEqual(@as(usize, 1), missed.items.len);
    try testing.expectEqual(@as(usize, 0), t.store.queued.items.len);
}

test "validateUpdate rejects key fields and unknown fields" {
    var t = TestWorld.init();
    defer t.deinit();
    const approval = try t.addApproval();
    try testing.expectError(error.KeyFieldUpdate, t.store.validateUpdate(approval, try t.sym("bloc"), .{ .symbol = try t.sym("x") }));
    try testing.expectError(error.UnknownField, t.store.validateUpdate(approval, try t.sym("nope"), .{ .float = 0 }));
}

test "state hash tracks content, not insertion order" {
    var t1 = TestWorld.init();
    defer t1.deinit();
    var t2 = TestWorld.init();
    defer t2.deinit();

    const a1 = t1.arena.allocator();
    const a2 = t2.arena.allocator();
    const s1 = try t1.addApproval();
    const s2 = try t2.addApproval();
    const rows_fwd = [_][2]Value{
        .{ .{ .symbol = try t1.sym("north") }, .{ .float = 0.6 } },
        .{ .{ .symbol = try t1.sym("south") }, .{ .float = 0.5 } },
    };
    // Same interning order (symbol ids must match), reversed insert order.
    _ = try t2.sym("north");
    _ = try t2.sym("south");
    try t1.store.insert(a1, s1, &rows_fwd[0]);
    try t1.store.insert(a1, s1, &rows_fwd[1]);
    try t2.store.insert(a2, s2, &.{ .{ .symbol = try t2.sym("south") }, .{ .float = 0.5 } });
    try t2.store.insert(a2, s2, &.{ .{ .symbol = try t2.sym("north") }, .{ .float = 0.6 } });

    var h1 = hash.StateHasher.init();
    var h2 = hash.StateHasher.init();
    try t1.store.feedStateHash(a1, &h1);
    try t2.store.feedStateHash(a2, &h2);
    try testing.expectEqualSlices(u8, &h1.finish(), &h2.finish());
}
