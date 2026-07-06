//! Typed IR for the statute DSL — the stable contract personas compile
//! against (dsl-sketch.md §11). Decode-only in M1: the JSON decoder is
//! hand-rolled over std.json.Value because the IR is a recursive tagged
//! union. All decoded nodes live in the caller's arena; all strings are
//! interned, so nothing references the source JSON after decoding.

const std = @import("std");
const intern = @import("intern.zig");
const value_mod = @import("value.zig");

pub const Symbol = intern.Symbol;
pub const Value = value_mod.Value;

pub const FieldType = enum { int, float, boolean, symbol };

pub const Field = struct { name: Symbol, ty: FieldType };

pub const Schema = struct {
    name: Symbol,
    fields: []const Field,
    /// The first `key_len` fields form the row key.
    key_len: u8,

    pub fn fieldIndex(self: Schema, name: Symbol) ?usize {
        for (self.fields, 0..) |f, i| {
            if (f.name == name) return i;
        }
        return null;
    }
};

pub const BinOp = enum { add, sub, mul, div, eq, lt, gt, @"and", @"or" };

pub const Expr = union(enum) {
    lit: Value,
    field: FieldRef,
    /// Sugar: single-row lookup in the `param` schema by name.
    param: Symbol,
    bin: Bin,
    not: *const Expr,

    pub const FieldRef = struct { row_var: Symbol, field_name: Symbol };
    pub const Bin = struct { op: BinOp, lhs: *const Expr, rhs: *const Expr };
};

pub const UpdateOp = enum { set, add };

pub const Action = union(enum) {
    emit: Emit,
    update: Update,
    foreach: Foreach,

    pub const Emit = struct { event: Symbol, args: []const Expr };
    pub const Update = struct {
        schema: Symbol,
        key: []const Expr,
        field: Symbol,
        op: UpdateOp,
        value: *const Expr,
    };
    pub const Foreach = struct { schema: Symbol, bind: Symbol, body: []const Action };
};

pub const Rule = struct {
    name: Symbol,
    on: Symbol,
    priority: i32,
    when: *const Expr,
    do: []const Action,
};

pub const AddFact = struct { schema: Symbol, values: []const Value };

pub const DiffOp = union(enum) {
    add_schema: Schema,
    add_rule: Rule,
    add_fact: AddFact,
};

pub const DecodeError = error{ BadIr, OutOfMemory };

/// Decodes diff payloads. Tracks schemas seen across payloads so `add_fact`
/// values can be typed against schemas declared earlier in the same genesis
/// sequence.
pub const Decoder = struct {
    /// IR nodes and slices are allocated here (world's IR arena).
    arena: std.mem.Allocator,
    /// Interner allocations (world's gpa).
    gpa: std.mem.Allocator,
    interner: *intern.Interner,
    schemas: std.AutoArrayHashMapUnmanaged(Symbol, Schema) = .empty,

    pub fn init(arena: std.mem.Allocator, gpa: std.mem.Allocator, interner: *intern.Interner) Decoder {
        return .{ .arena = arena, .gpa = gpa, .interner = interner };
    }

    pub fn deinit(self: *Decoder) void {
        self.schemas.deinit(self.gpa);
    }

    /// A diff payload is a JSON array of ops.
    pub fn decodePayload(self: *Decoder, json: std.json.Value) DecodeError![]DiffOp {
        if (json != .array) return error.BadIr;
        const ops = try self.arena.alloc(DiffOp, json.array.items.len);
        for (json.array.items, 0..) |item, i| {
            ops[i] = try self.decodeOp(item);
        }
        return ops;
    }

    fn decodeOp(self: *Decoder, json: std.json.Value) DecodeError!DiffOp {
        const kv = try singleKey(json);
        if (std.mem.eql(u8, kv.key, "add_schema")) {
            const schema = try self.decodeSchema(kv.val);
            try self.schemas.put(self.gpa, schema.name, schema);
            return .{ .add_schema = schema };
        } else if (std.mem.eql(u8, kv.key, "add_rule")) {
            return .{ .add_rule = try self.decodeRule(kv.val) };
        } else if (std.mem.eql(u8, kv.key, "add_fact")) {
            return .{ .add_fact = try self.decodeFact(kv.val) };
        }
        return error.BadIr;
    }

    fn decodeSchema(self: *Decoder, json: std.json.Value) DecodeError!Schema {
        const obj = try object(json);
        const name = try self.internSym(obj.get("name") orelse return error.BadIr);
        const fields_json = obj.get("fields") orelse return error.BadIr;
        if (fields_json != .array) return error.BadIr;
        const key_json = obj.get("key") orelse return error.BadIr;
        if (key_json != .integer) return error.BadIr;

        const fields = try self.arena.alloc(Field, fields_json.array.items.len);
        for (fields_json.array.items, 0..) |fj, i| {
            if (fj != .array or fj.array.items.len != 2) return error.BadIr;
            const fname = try self.internSym(fj.array.items[0]);
            const ftype_json = fj.array.items[1];
            if (ftype_json != .string) return error.BadIr;
            const ty = std.meta.stringToEnum(FieldType, ftype_json.string) orelse return error.BadIr;
            fields[i] = .{ .name = fname, .ty = ty };
        }
        if (key_json.integer < 1 or key_json.integer > fields.len) return error.BadIr;
        return .{ .name = name, .fields = fields, .key_len = @intCast(key_json.integer) };
    }

    fn decodeRule(self: *Decoder, json: std.json.Value) DecodeError!Rule {
        const obj = try object(json);
        const priority: i32 = if (obj.get("priority")) |p| blk: {
            if (p != .integer) return error.BadIr;
            break :blk std.math.cast(i32, p.integer) orelse return error.BadIr;
        } else 0;
        return .{
            .name = try self.internSym(obj.get("name") orelse return error.BadIr),
            .on = try self.internSym(obj.get("on") orelse return error.BadIr),
            .priority = priority,
            .when = try self.decodeExpr(obj.get("when") orelse return error.BadIr),
            .do = try self.decodeActions(obj.get("do") orelse return error.BadIr),
        };
    }

    fn decodeFact(self: *Decoder, json: std.json.Value) DecodeError!AddFact {
        const obj = try object(json);
        const schema_sym = try self.internSym(obj.get("schema") orelse return error.BadIr);
        const schema = self.schemas.get(schema_sym) orelse return error.BadIr;
        const values_json = obj.get("values") orelse return error.BadIr;
        if (values_json != .array) return error.BadIr;
        if (values_json.array.items.len != schema.fields.len) return error.BadIr;

        const values = try self.arena.alloc(Value, schema.fields.len);
        for (values_json.array.items, schema.fields, 0..) |vj, f, i| {
            values[i] = try self.decodeTypedValue(f.ty, vj);
        }
        return .{ .schema = schema_sym, .values = values };
    }

    fn decodeActions(self: *Decoder, json: std.json.Value) DecodeError![]Action {
        if (json != .array) return error.BadIr;
        const actions = try self.arena.alloc(Action, json.array.items.len);
        for (json.array.items, 0..) |item, i| {
            actions[i] = try self.decodeAction(item);
        }
        return actions;
    }

    fn decodeAction(self: *Decoder, json: std.json.Value) DecodeError!Action {
        const kv = try singleKey(json);
        const obj = try object(kv.val);
        if (std.mem.eql(u8, kv.key, "emit")) {
            const event_json = obj.get("event") orelse return error.BadIr;
            if (event_json != .string) return error.BadIr;
            // The tick.* namespace is kernel-only; user rules may not forge it.
            if (std.mem.startsWith(u8, event_json.string, "tick.")) return error.BadIr;
            const args_json = obj.get("args") orelse return error.BadIr;
            if (args_json != .array) return error.BadIr;
            const args = try self.arena.alloc(Expr, args_json.array.items.len);
            for (args_json.array.items, 0..) |aj, i| {
                args[i] = (try self.decodeExpr(aj)).*;
            }
            return .{ .emit = .{
                .event = try self.internSym(event_json),
                .args = args,
            } };
        } else if (std.mem.eql(u8, kv.key, "update")) {
            const op_json = obj.get("op") orelse return error.BadIr;
            if (op_json != .string) return error.BadIr;
            const key_json = obj.get("key") orelse return error.BadIr;
            if (key_json != .array) return error.BadIr;
            const key = try self.arena.alloc(Expr, key_json.array.items.len);
            for (key_json.array.items, 0..) |kj, i| {
                key[i] = (try self.decodeExpr(kj)).*;
            }
            return .{ .update = .{
                .schema = try self.internSym(obj.get("schema") orelse return error.BadIr),
                .key = key,
                .field = try self.internSym(obj.get("field") orelse return error.BadIr),
                .op = std.meta.stringToEnum(UpdateOp, op_json.string) orelse return error.BadIr,
                .value = try self.decodeExpr(obj.get("value") orelse return error.BadIr),
            } };
        } else if (std.mem.eql(u8, kv.key, "foreach")) {
            return .{ .foreach = .{
                .schema = try self.internSym(obj.get("schema") orelse return error.BadIr),
                .bind = try self.internSym(obj.get("bind") orelse return error.BadIr),
                .body = try self.decodeActions(obj.get("do") orelse return error.BadIr),
            } };
        }
        return error.BadIr;
    }

    fn decodeExpr(self: *Decoder, json: std.json.Value) DecodeError!*const Expr {
        const kv = try singleKey(json);
        const e = try self.arena.create(Expr);
        if (std.mem.eql(u8, kv.key, "lit")) {
            e.* = .{ .lit = try self.decodeValue(kv.val) };
        } else if (std.mem.eql(u8, kv.key, "field")) {
            if (kv.val != .array or kv.val.array.items.len != 2) return error.BadIr;
            e.* = .{ .field = .{
                .row_var = try self.internSym(kv.val.array.items[0]),
                .field_name = try self.internSym(kv.val.array.items[1]),
            } };
        } else if (std.mem.eql(u8, kv.key, "param")) {
            e.* = .{ .param = try self.internSym(kv.val) };
        } else if (std.mem.eql(u8, kv.key, "bin")) {
            if (kv.val != .array or kv.val.array.items.len != 3) return error.BadIr;
            const op_json = kv.val.array.items[0];
            if (op_json != .string) return error.BadIr;
            e.* = .{ .bin = .{
                .op = std.meta.stringToEnum(BinOp, op_json.string) orelse return error.BadIr,
                .lhs = try self.decodeExpr(kv.val.array.items[1]),
                .rhs = try self.decodeExpr(kv.val.array.items[2]),
            } };
        } else if (std.mem.eql(u8, kv.key, "not")) {
            e.* = .{ .not = try self.decodeExpr(kv.val) };
        } else {
            return error.BadIr;
        }
        return e;
    }

    /// Untyped literal: JSON type determines the tag; strings intern to
    /// symbols. NaN floats are rejected (they have no total order).
    fn decodeValue(self: *Decoder, json: std.json.Value) DecodeError!Value {
        return switch (json) {
            .integer => |v| .{ .int = v },
            .float => |v| if (std.math.isNan(v)) error.BadIr else .{ .float = v },
            .bool => |v| .{ .boolean = v },
            .string => .{ .symbol = try self.internSym(json) },
            else => error.BadIr,
        };
    }

    /// Fact values decode against the schema's field type; JSON integers
    /// coerce to float fields.
    fn decodeTypedValue(self: *Decoder, ty: FieldType, json: std.json.Value) DecodeError!Value {
        return switch (ty) {
            .int => if (json == .integer) .{ .int = json.integer } else error.BadIr,
            .float => switch (json) {
                .integer => |v| .{ .float = @floatFromInt(v) },
                .float => |v| if (std.math.isNan(v)) error.BadIr else .{ .float = v },
                else => error.BadIr,
            },
            .boolean => if (json == .bool) .{ .boolean = json.bool } else error.BadIr,
            .symbol => if (json == .string) .{ .symbol = try self.internSym(json) } else error.BadIr,
        };
    }

    fn internSym(self: *Decoder, json: std.json.Value) DecodeError!Symbol {
        if (json != .string) return error.BadIr;
        return self.interner.intern(self.gpa, json.string) catch error.OutOfMemory;
    }
};

const KeyVal = struct { key: []const u8, val: std.json.Value };

fn singleKey(json: std.json.Value) DecodeError!KeyVal {
    if (json != .object) return error.BadIr;
    if (json.object.count() != 1) return error.BadIr;
    return .{ .key = json.object.keys()[0], .val = json.object.values()[0] };
}

fn object(json: std.json.Value) DecodeError!std.json.ObjectMap {
    if (json != .object) return error.BadIr;
    return json.object;
}

const TestSetup = struct {
    arena: std.heap.ArenaAllocator,
    interner: intern.Interner = .{},
    decoder: Decoder = undefined,

    fn init() TestSetup {
        return .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    }

    fn deinit(self: *TestSetup) void {
        self.decoder.deinit();
        self.interner.deinit(std.testing.allocator);
        self.arena.deinit();
    }

    fn decode(self: *TestSetup, source: []const u8) ![]DiffOp {
        self.decoder = Decoder.init(self.arena.allocator(), std.testing.allocator, &self.interner);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), source, .{});
        return self.decoder.decodePayload(parsed);
    }
};

test "decodes schema, fact, and rule ops" {
    var t = TestSetup.init();
    defer t.deinit();

    const ops = try t.decode(
        \\[
        \\ {"add_schema":{"name":"population","fields":[["bloc","symbol"],["count","int"]],"key":1}},
        \\ {"add_fact":{"schema":"population","values":["north",1000]}},
        \\ {"add_rule":{"name":"r","on":"tick.quarter","when":{"lit":true},"do":[
        \\   {"foreach":{"schema":"population","bind":"p","do":[
        \\     {"update":{"schema":"population","key":[{"field":["p","bloc"]}],"field":"count","op":"add",
        \\       "value":{"bin":["mul",{"lit":2},{"param":"rate"}]}}}
        \\   ]}}
        \\ ]}}
        \\]
    );

    try std.testing.expectEqual(@as(usize, 3), ops.len);
    const schema = ops[0].add_schema;
    try std.testing.expectEqual(@as(u8, 1), schema.key_len);
    try std.testing.expectEqual(FieldType.int, schema.fields[1].ty);

    const fact = ops[1].add_fact;
    try std.testing.expectEqual(schema.name, fact.schema);
    try std.testing.expectEqual(Value{ .int = 1000 }, fact.values[1]);

    const rule = ops[2].add_rule;
    try std.testing.expectEqual(@as(i32, 0), rule.priority);
    const body = rule.do[0].foreach.body;
    try std.testing.expectEqual(UpdateOp.add, body[0].update.op);
    try std.testing.expectEqual(BinOp.mul, body[0].update.value.bin.op);
}

test "rejects malformed IR" {
    const cases = [_][]const u8{
        "[{\"bogus\":{}}]",
        "[{\"add_fact\":{\"schema\":\"nope\",\"values\":[]}}]", // unknown schema
        "[{\"add_schema\":{\"name\":\"s\",\"fields\":[[\"a\",\"int\"]],\"key\":2}}]", // key > fields
        // Forged kernel event in emit:
        "[{\"add_rule\":{\"name\":\"r\",\"on\":\"e\",\"when\":{\"lit\":true},\"do\":[{\"emit\":{\"event\":\"tick.start\",\"args\":[]}}]}}]",
    };
    for (cases) |case| {
        var t = TestSetup.init();
        defer t.deinit();
        try std.testing.expectError(error.BadIr, t.decode(case));
    }
}
