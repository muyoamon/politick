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
    layer: Symbol,

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
    /// Row-presence test — the §5 capability check in expression form.
    exists: Exists,
    /// Single-row field read by key — `param` generalized to any schema.
    lookup: Lookup,

    pub const FieldRef = struct { row_var: Symbol, field_name: Symbol };
    pub const Bin = struct { op: BinOp, lhs: *const Expr, rhs: *const Expr };
    pub const Exists = struct { schema: Symbol, key: []const Expr };
    pub const Lookup = struct { schema: Symbol, key: []const Expr, field: Symbol };
};

pub const UpdateOp = enum { set, add };

pub const Action = union(enum) {
    emit: Emit,
    update: Update,
    foreach: Foreach,
    /// Stage a diff for COMMIT validation. The embedded diff's contents are
    /// validated when it commits, not when the containing rule is checked.
    stage: *const Diff,
    /// Start a procedure instance carrying `bill`. The procedure resolves by
    /// name when the action fires (§2.4 — never cached); a missing procedure
    /// aborts with a kernel event, not an error.
    begin: Begin,

    pub const Emit = struct { event: Symbol, args: []const Expr };
    pub const Begin = struct { procedure: Symbol, bill: *const Diff };
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
    layer: Symbol,
    when: *const Expr,
    do: []const Action,
};

pub const Step = struct {
    name: Symbol,
    /// Evaluated with the instance's proc_instance row bound to `instance`.
    requires: *const Expr,
};

/// Multi-step protocol (§2.4): a named step sequence over an instance state
/// machine. First-class so actors can query "how do I pass a statute";
/// completing the final step stages the carried bill (kernel semantics).
pub const Procedure = struct {
    name: Symbol,
    layer: Symbol,
    steps: []const Step,

    pub fn stepIndex(self: Procedure, name: Symbol) ?usize {
        for (self.steps, 0..) |s, i| {
            if (s.name == name) return i;
        }
        return null;
    }
};

/// Amendment rule: governs diffs touching terms at `governs_layer`.
pub const Meta = struct {
    name: Symbol,
    layer: Symbol,
    governs_layer: Symbol,
    /// Ticks a diff must survive staged before it may commit (§2.5 delay).
    min_staged_ticks: u32,
    /// Evaluated with the diff's staged_diff fact row bound to var `diff`.
    allow: *const Expr,
};

pub const AddFact = struct { schema: Symbol, values: []const Value };

pub const RemoveFact = struct { schema: Symbol, key: []const Value };

/// The statute object (§3): a named op set with provenance.
pub const Diff = struct {
    name: Symbol,
    layer: Symbol,
    by: Symbol,
    via: Symbol,
    ops: []const DiffOp,
};

/// An external event from the log (driver input): literal args only, no
/// expressions — drivers send values, not programs.
pub const ExternalEvent = struct { name: Symbol, args: []const Value };

pub const DiffOp = union(enum) {
    add_schema: Schema,
    add_rule: Rule,
    add_meta: Meta,
    add_procedure: Procedure,
    add_fact: AddFact,
    remove_schema: Symbol,
    remove_rule: Symbol,
    remove_meta: Symbol,
    remove_procedure: Symbol,
    remove_fact: RemoveFact,
};

pub const DecodeError = error{ BadIr, OutOfMemory };

/// Structured detail for the first `BadIr` a decode call produced — recorded
/// only when the caller attaches a `Diag` via `Decoder.diag` (default null,
/// so existing callers see identical bare-`error.BadIr` behavior). Mirrors
/// check.zig's `Ctx.diag`/`Diag` pattern: a `politick check` rejection during
/// decode can now report *what* was wrong the same way a post-decode
/// validation rejection already does, instead of a bare "bad_ir".
pub const Diag = struct {
    /// Short, stable code naming the failure kind, e.g. "missing_field",
    /// "arity_mismatch", "unknown_schema", "bad_value_type", "unknown_op".
    code: ?[]const u8 = null,
    /// The primary offending symbol: a schema name, an unrecognized op/
    /// expr/action tag, a missing or mistyped JSON key, or similar.
    symbol: ?Symbol = null,
    /// A secondary symbol, e.g. the field within `symbol`'s schema.
    field: ?Symbol = null,
    expected: ?u32 = null,
    got: ?u32 = null,
};

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
    /// Optional out-slot for the first failure's structured detail.
    diag: ?*Diag = null,

    pub fn init(arena: std.mem.Allocator, gpa: std.mem.Allocator, interner: *intern.Interner) Decoder {
        return .{ .arena = arena, .gpa = gpa, .interner = interner };
    }

    pub fn deinit(self: *Decoder) void {
        self.schemas.deinit(self.gpa);
    }

    /// Records `code`/context on the first failure only (later fails while
    /// unwinding are noise) and returns `error.BadIr`.
    fn fail(self: *Decoder, code: []const u8, opts: struct {
        symbol: ?Symbol = null,
        field: ?Symbol = null,
        expected: ?u32 = null,
        got: ?u32 = null,
    }) DecodeError {
        if (self.diag) |d| {
            if (d.code == null) d.* = .{ .code = code, .symbol = opts.symbol, .field = opts.field, .expected = opts.expected, .got = opts.got };
        }
        return error.BadIr;
    }

    /// `obj.get(key) orelse return self.missingField(key)` — the single
    /// most common failure shape in this decoder.
    fn missingField(self: *Decoder, key: []const u8) DecodeError {
        const sym = try self.internStr(key);
        return self.fail("missing_field", .{ .field = sym });
    }

    /// A JSON value present under `key` but of the wrong shape/type.
    fn badType(self: *Decoder, key: []const u8) DecodeError {
        const sym = try self.internStr(key);
        return self.fail("bad_type", .{ .field = sym });
    }

    fn internStr(self: *Decoder, s: []const u8) DecodeError!Symbol {
        return self.interner.intern(self.gpa, s) catch error.OutOfMemory;
    }

    /// A genesis diff payload is a bare JSON array of ops.
    pub fn decodePayload(self: *Decoder, json: std.json.Value) DecodeError![]DiffOp {
        if (json != .array) return self.badType("ops");
        const ops = try self.arena.alloc(DiffOp, json.array.items.len);
        for (json.array.items, 0..) |item, i| {
            ops[i] = try self.decodeOp(item);
        }
        return ops;
    }

    /// A proper diff object: `{name, layer?, by, via, ops:[…]}`.
    pub fn decodeDiffObject(self: *Decoder, json: std.json.Value) DecodeError!Diff {
        const obj = try self.object(json);
        return .{
            .name = try self.internSym(obj.get("name") orelse return self.missingField("name")),
            .layer = try self.layerOf(obj),
            .by = try self.internSym(obj.get("by") orelse return self.missingField("by")),
            .via = try self.internSym(obj.get("via") orelse return self.missingField("via")),
            .ops = try self.decodePayload(obj.get("ops") orelse return self.missingField("ops")),
        };
    }

    /// An external event entry payload: `{name, args:[…]}`. Args are
    /// untyped literals. The kernel tick.* namespace is rejected, giving
    /// external actors exactly the powers of a rule's emit — no more.
    pub fn decodeEventObject(self: *Decoder, json: std.json.Value) DecodeError!ExternalEvent {
        const obj = try self.object(json);
        const name_json = obj.get("name") orelse return self.missingField("name");
        if (name_json != .string) return self.badType("name");
        if (std.mem.startsWith(u8, name_json.string, "tick.")) return self.fail("reserved_event_namespace", .{});
        const args_json = obj.get("args") orelse return self.missingField("args");
        if (args_json != .array) return self.badType("args");
        const args = try self.arena.alloc(Value, args_json.array.items.len);
        for (args_json.array.items, 0..) |aj, i| {
            args[i] = try self.decodeValue(aj);
        }
        return .{ .name = try self.internSym(name_json), .args = args };
    }

    /// An external begin entry payload: `{procedure, bill:{…}}` — the same
    /// shape as the in-DSL begin action body.
    pub fn decodeBeginObject(self: *Decoder, json: std.json.Value) DecodeError!Action.Begin {
        const obj = try self.object(json);
        const bill = try self.arena.create(Diff);
        bill.* = try self.decodeDiffObject(obj.get("bill") orelse return self.missingField("bill"));
        return .{
            .procedure = try self.internSym(obj.get("procedure") orelse return self.missingField("procedure")),
            .bill = bill,
        };
    }

    fn decodeOp(self: *Decoder, json: std.json.Value) DecodeError!DiffOp {
        const kv = try self.singleKey(json);
        if (std.mem.eql(u8, kv.key, "add_schema")) {
            const schema = try self.decodeSchema(kv.val);
            try self.schemas.put(self.gpa, schema.name, schema);
            return .{ .add_schema = schema };
        } else if (std.mem.eql(u8, kv.key, "add_rule")) {
            return .{ .add_rule = try self.decodeRule(kv.val) };
        } else if (std.mem.eql(u8, kv.key, "add_meta")) {
            return .{ .add_meta = try self.decodeMeta(kv.val) };
        } else if (std.mem.eql(u8, kv.key, "add_procedure")) {
            return .{ .add_procedure = try self.decodeProcedure(kv.val) };
        } else if (std.mem.eql(u8, kv.key, "add_fact")) {
            return .{ .add_fact = try self.decodeFact(kv.val) };
        } else if (std.mem.eql(u8, kv.key, "remove_schema")) {
            return .{ .remove_schema = try self.internSym(kv.val) };
        } else if (std.mem.eql(u8, kv.key, "remove_rule")) {
            return .{ .remove_rule = try self.internSym(kv.val) };
        } else if (std.mem.eql(u8, kv.key, "remove_meta")) {
            return .{ .remove_meta = try self.internSym(kv.val) };
        } else if (std.mem.eql(u8, kv.key, "remove_procedure")) {
            return .{ .remove_procedure = try self.internSym(kv.val) };
        } else if (std.mem.eql(u8, kv.key, "remove_fact")) {
            const obj = try self.object(kv.val);
            const key_json = obj.get("key") orelse return self.missingField("key");
            if (key_json != .array) return self.badType("key");
            const key = try self.arena.alloc(Value, key_json.array.items.len);
            // Untyped decode: key values match rows by tag + payload, so a
            // JSON key must use the same representation the schema stores.
            for (key_json.array.items, 0..) |kj, i| {
                key[i] = try self.decodeValue(kj);
            }
            return .{ .remove_fact = .{
                .schema = try self.internSym(obj.get("schema") orelse return self.missingField("schema")),
                .key = key,
            } };
        }
        return self.fail("unknown_op", .{ .symbol = try self.internStr(kv.key) });
    }

    fn decodeMeta(self: *Decoder, json: std.json.Value) DecodeError!Meta {
        const obj = try self.object(json);
        const min: u32 = if (obj.get("min_staged_ticks")) |m| blk: {
            if (m != .integer) return self.badType("min_staged_ticks");
            break :blk std.math.cast(u32, m.integer) orelse return self.badType("min_staged_ticks");
        } else 0;
        return .{
            .name = try self.internSym(obj.get("name") orelse return self.missingField("name")),
            .layer = try self.layerOf(obj),
            .governs_layer = try self.internSym(obj.get("governs") orelse return self.missingField("governs")),
            .min_staged_ticks = min,
            .allow = try self.decodeExpr(obj.get("allow") orelse return self.missingField("allow")),
        };
    }

    fn decodeProcedure(self: *Decoder, json: std.json.Value) DecodeError!Procedure {
        const obj = try self.object(json);
        const steps_json = obj.get("steps") orelse return self.missingField("steps");
        if (steps_json != .array) return self.badType("steps");
        // Instances track their position by step name (re-resolve per step,
        // §8.1), so steps must be non-empty and uniquely named.
        if (steps_json.array.items.len == 0) return self.fail("empty_steps", .{});
        const steps = try self.arena.alloc(Step, steps_json.array.items.len);
        for (steps_json.array.items, 0..) |sj, i| {
            const sobj = try self.object(sj);
            const step = Step{
                .name = try self.internSym(sobj.get("name") orelse return self.missingField("name")),
                .requires = try self.decodeExpr(sobj.get("requires") orelse return self.missingField("requires")),
            };
            for (steps[0..i]) |prev| {
                if (prev.name == step.name) return self.fail("duplicate_step", .{ .symbol = step.name });
            }
            steps[i] = step;
        }
        return .{
            .name = try self.internSym(obj.get("name") orelse return self.missingField("name")),
            .layer = try self.layerOf(obj),
            .steps = steps,
        };
    }

    fn layerOf(self: *Decoder, obj: std.json.ObjectMap) DecodeError!Symbol {
        if (obj.get("layer")) |l| return self.internSym(l);
        return self.interner.intern(self.gpa, "statute") catch error.OutOfMemory;
    }

    fn decodeSchema(self: *Decoder, json: std.json.Value) DecodeError!Schema {
        const obj = try self.object(json);
        const name = try self.internSym(obj.get("name") orelse return self.missingField("name"));
        const fields_json = obj.get("fields") orelse return self.missingField("fields");
        if (fields_json != .array) return self.badType("fields");
        const key_json = obj.get("key") orelse return self.missingField("key");
        if (key_json != .integer) return self.badType("key");

        const fields = try self.arena.alloc(Field, fields_json.array.items.len);
        for (fields_json.array.items, 0..) |fj, i| {
            if (fj != .array or fj.array.items.len != 2) return self.badType("fields");
            const fname = try self.internSym(fj.array.items[0]);
            const ftype_json = fj.array.items[1];
            if (ftype_json != .string) return self.badType("fields");
            const ty = std.meta.stringToEnum(FieldType, ftype_json.string) orelse
                return self.fail("unknown_field_type", .{ .symbol = name, .field = fname });
            fields[i] = .{ .name = fname, .ty = ty };
        }
        if (key_json.integer < 1 or key_json.integer > fields.len) return self.fail("key_arity", .{
            .symbol = name,
            .expected = @intCast(fields.len),
            .got = std.math.cast(u32, key_json.integer) orelse 0,
        });
        return .{
            .name = name,
            .fields = fields,
            .key_len = @intCast(key_json.integer),
            .layer = try self.layerOf(obj),
        };
    }

    fn decodeRule(self: *Decoder, json: std.json.Value) DecodeError!Rule {
        const obj = try self.object(json);
        const priority: i32 = if (obj.get("priority")) |p| blk: {
            if (p != .integer) return self.badType("priority");
            break :blk std.math.cast(i32, p.integer) orelse return self.badType("priority");
        } else 0;
        return .{
            .name = try self.internSym(obj.get("name") orelse return self.missingField("name")),
            .on = try self.internSym(obj.get("on") orelse return self.missingField("on")),
            .priority = priority,
            .layer = try self.layerOf(obj),
            .when = try self.decodeExpr(obj.get("when") orelse return self.missingField("when")),
            .do = try self.decodeActions(obj.get("do") orelse return self.missingField("do")),
        };
    }

    fn decodeFact(self: *Decoder, json: std.json.Value) DecodeError!AddFact {
        const obj = try self.object(json);
        const schema_sym = try self.internSym(obj.get("schema") orelse return self.missingField("schema"));
        const schema = self.schemas.get(schema_sym) orelse return self.fail("unknown_schema", .{ .symbol = schema_sym });
        const values_json = obj.get("values") orelse return self.missingField("values");
        if (values_json != .array) return self.badType("values");
        if (values_json.array.items.len != schema.fields.len) return self.fail("arity_mismatch", .{
            .symbol = schema_sym,
            .expected = @intCast(schema.fields.len),
            .got = @intCast(values_json.array.items.len),
        });

        const values = try self.arena.alloc(Value, schema.fields.len);
        for (values_json.array.items, schema.fields, 0..) |vj, f, i| {
            values[i] = self.decodeTypedValue(f.ty, vj) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadIr => return self.fail("bad_value_type", .{ .symbol = schema_sym, .field = f.name }),
            };
        }
        return .{ .schema = schema_sym, .values = values };
    }

    fn decodeActions(self: *Decoder, json: std.json.Value) DecodeError![]Action {
        if (json != .array) return self.badType("do");
        const actions = try self.arena.alloc(Action, json.array.items.len);
        for (json.array.items, 0..) |item, i| {
            actions[i] = try self.decodeAction(item);
        }
        return actions;
    }

    fn decodeAction(self: *Decoder, json: std.json.Value) DecodeError!Action {
        const kv = try self.singleKey(json);
        const obj = try self.object(kv.val);
        if (std.mem.eql(u8, kv.key, "emit")) {
            const event_json = obj.get("event") orelse return self.missingField("event");
            if (event_json != .string) return self.badType("event");
            // The tick.* namespace is kernel-only; user rules may not forge it.
            if (std.mem.startsWith(u8, event_json.string, "tick.")) return self.fail("reserved_event_namespace", .{});
            const args_json = obj.get("args") orelse return self.missingField("args");
            if (args_json != .array) return self.badType("args");
            const args = try self.arena.alloc(Expr, args_json.array.items.len);
            for (args_json.array.items, 0..) |aj, i| {
                args[i] = (try self.decodeExpr(aj)).*;
            }
            return .{ .emit = .{
                .event = try self.internSym(event_json),
                .args = args,
            } };
        } else if (std.mem.eql(u8, kv.key, "update")) {
            const op_json = obj.get("op") orelse return self.missingField("op");
            if (op_json != .string) return self.badType("op");
            const key_json = obj.get("key") orelse return self.missingField("key");
            if (key_json != .array) return self.badType("key");
            const key = try self.arena.alloc(Expr, key_json.array.items.len);
            for (key_json.array.items, 0..) |kj, i| {
                key[i] = (try self.decodeExpr(kj)).*;
            }
            return .{ .update = .{
                .schema = try self.internSym(obj.get("schema") orelse return self.missingField("schema")),
                .key = key,
                .field = try self.internSym(obj.get("field") orelse return self.missingField("field")),
                .op = std.meta.stringToEnum(UpdateOp, op_json.string) orelse
                    return self.fail("unknown_update_op", .{ .symbol = try self.internStr(op_json.string) }),
                .value = try self.decodeExpr(obj.get("value") orelse return self.missingField("value")),
            } };
        } else if (std.mem.eql(u8, kv.key, "foreach")) {
            return .{ .foreach = .{
                .schema = try self.internSym(obj.get("schema") orelse return self.missingField("schema")),
                .bind = try self.internSym(obj.get("bind") orelse return self.missingField("bind")),
                .body = try self.decodeActions(obj.get("do") orelse return self.missingField("do")),
            } };
        } else if (std.mem.eql(u8, kv.key, "stage")) {
            const diff = try self.arena.create(Diff);
            diff.* = try self.decodeDiffObject(kv.val);
            return .{ .stage = diff };
        } else if (std.mem.eql(u8, kv.key, "begin")) {
            return .{ .begin = try self.decodeBeginObject(kv.val) };
        }
        return self.fail("unknown_action", .{ .symbol = try self.internStr(kv.key) });
    }

    fn decodeExpr(self: *Decoder, json: std.json.Value) DecodeError!*const Expr {
        const kv = try self.singleKey(json);
        const e = try self.arena.create(Expr);
        if (std.mem.eql(u8, kv.key, "lit")) {
            e.* = .{ .lit = try self.decodeValue(kv.val) };
        } else if (std.mem.eql(u8, kv.key, "field")) {
            if (kv.val != .array or kv.val.array.items.len != 2) return self.badType("field");
            e.* = .{ .field = .{
                .row_var = try self.internSym(kv.val.array.items[0]),
                .field_name = try self.internSym(kv.val.array.items[1]),
            } };
        } else if (std.mem.eql(u8, kv.key, "param")) {
            e.* = .{ .param = try self.internSym(kv.val) };
        } else if (std.mem.eql(u8, kv.key, "bin")) {
            if (kv.val != .array or kv.val.array.items.len != 3) return self.badType("bin");
            const op_json = kv.val.array.items[0];
            if (op_json != .string) return self.badType("bin");
            e.* = .{ .bin = .{
                .op = std.meta.stringToEnum(BinOp, op_json.string) orelse
                    return self.fail("unknown_bin_op", .{ .symbol = try self.internStr(op_json.string) }),
                .lhs = try self.decodeExpr(kv.val.array.items[1]),
                .rhs = try self.decodeExpr(kv.val.array.items[2]),
            } };
        } else if (std.mem.eql(u8, kv.key, "not")) {
            e.* = .{ .not = try self.decodeExpr(kv.val) };
        } else if (std.mem.eql(u8, kv.key, "exists")) {
            const obj = try self.object(kv.val);
            const key_json = obj.get("key") orelse return self.missingField("key");
            if (key_json != .array) return self.badType("key");
            const key = try self.arena.alloc(Expr, key_json.array.items.len);
            for (key_json.array.items, 0..) |kj, i| {
                key[i] = (try self.decodeExpr(kj)).*;
            }
            e.* = .{ .exists = .{
                .schema = try self.internSym(obj.get("schema") orelse return self.missingField("schema")),
                .key = key,
            } };
        } else if (std.mem.eql(u8, kv.key, "lookup")) {
            const obj = try self.object(kv.val);
            const key_json = obj.get("key") orelse return self.missingField("key");
            if (key_json != .array) return self.badType("key");
            const key = try self.arena.alloc(Expr, key_json.array.items.len);
            for (key_json.array.items, 0..) |kj, i| {
                key[i] = (try self.decodeExpr(kj)).*;
            }
            e.* = .{ .lookup = .{
                .schema = try self.internSym(obj.get("schema") orelse return self.missingField("schema")),
                .key = key,
                .field = try self.internSym(obj.get("field") orelse return self.missingField("field")),
            } };
        } else {
            return self.fail("unknown_expr", .{ .symbol = try self.internStr(kv.key) });
        }
        return e;
    }

    /// Untyped literal: JSON type determines the tag; strings intern to
    /// symbols. NaN floats are rejected (they have no total order).
    fn decodeValue(self: *Decoder, json: std.json.Value) DecodeError!Value {
        return switch (json) {
            .integer => |v| .{ .int = v },
            .float => |v| if (std.math.isNan(v)) self.fail("nan_float", .{}) else .{ .float = v },
            .bool => |v| .{ .boolean = v },
            .string => .{ .symbol = try self.internSym(json) },
            else => self.fail("bad_type", .{}),
        };
    }

    /// Fact values decode against the schema's field type; JSON integers
    /// coerce to float fields. Failures here carry no diag of their own —
    /// `decodeFact` wraps this call and attaches the schema/field context,
    /// since this function alone doesn't know either.
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
        if (json != .string) return self.fail("bad_type", .{});
        return self.interner.intern(self.gpa, json.string) catch error.OutOfMemory;
    }

    fn singleKey(self: *Decoder, json: std.json.Value) DecodeError!KeyVal {
        if (json != .object) return self.fail("bad_type", .{});
        if (json.object.count() != 1) return self.fail("not_single_key", .{});
        return .{ .key = json.object.keys()[0], .val = json.object.values()[0] };
    }

    fn object(self: *Decoder, json: std.json.Value) DecodeError!std.json.ObjectMap {
        if (json != .object) return self.fail("bad_type", .{});
        return json.object;
    }
};

const KeyVal = struct { key: []const u8, val: std.json.Value };

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

    fn decodeWithDiag(self: *TestSetup, source: []const u8, diag: *Diag) ![]DiffOp {
        self.decoder = Decoder.init(self.arena.allocator(), std.testing.allocator, &self.interner);
        self.decoder.diag = diag;
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

test "decodes metas, removes, stage actions, and exists exprs" {
    var t = TestSetup.init();
    defer t.deinit();

    const ops = try t.decode(
        \\[
        \\ {"add_schema":{"name":"office","fields":[["name","symbol"],["holder","symbol"]],"key":2,"layer":"organic"}},
        \\ {"add_meta":{"name":"amend_statute","layer":"organic","governs":"statute","min_staged_ticks":2,
        \\   "allow":{"exists":{"schema":"office","key":[{"lit":"tax_office"},{"field":["diff","by"]}]}}}},
        \\ {"add_rule":{"name":"propose","on":"tick.quarter","when":{"lit":true},"do":[
        \\   {"stage":{"name":"act","by":"baron","via":"decree","ops":[
        \\     {"remove_schema":"office"},
        \\     {"remove_fact":{"schema":"office","key":["tax_office","baron"]}}
        \\   ]}}
        \\ ]}}
        \\]
    );

    const schema = ops[0].add_schema;
    try std.testing.expectEqualStrings("organic", t.interner.lookup(schema.layer));

    const meta = ops[1].add_meta;
    try std.testing.expectEqual(@as(u32, 2), meta.min_staged_ticks);
    try std.testing.expectEqual(schema.name, meta.allow.exists.schema);
    try std.testing.expectEqual(@as(usize, 2), meta.allow.exists.key.len);

    const rule = ops[2].add_rule;
    // layer defaults to statute when omitted
    try std.testing.expectEqualStrings("statute", t.interner.lookup(rule.layer));
    const diff = rule.do[0].stage;
    try std.testing.expectEqualStrings("baron", t.interner.lookup(diff.by));
    try std.testing.expectEqual(schema.name, diff.ops[0].remove_schema);
    try std.testing.expectEqual(@as(usize, 2), diff.ops[1].remove_fact.key.len);
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

test "decode failures attach structured diagnostics when a Diag is provided" {
    // add_fact arity mismatch: the driver's actual failure mode — a model
    // flattening field-name/value pairs into "values" instead of giving
    // positional values matching the schema's field order.
    {
        var t = TestSetup.init();
        defer t.deinit();
        var diag = Diag{};
        const source =
            \\[
            \\ {"add_schema":{"name":"param","fields":[["name","symbol"],["value","float"]],"key":1}},
            \\ {"add_fact":{"schema":"param","values":["name","poll_tax_rate","value",0.05]}}
            \\]
        ;
        try std.testing.expectError(error.BadIr, t.decodeWithDiag(source, &diag));
        try std.testing.expectEqualStrings("arity_mismatch", diag.code.?);
        try std.testing.expectEqualStrings("param", t.interner.lookup(diag.symbol.?));
        try std.testing.expectEqual(@as(u32, 2), diag.expected.?);
        try std.testing.expectEqual(@as(u32, 4), diag.got.?);
    }

    // add_fact against a schema that was never declared.
    {
        var t = TestSetup.init();
        defer t.deinit();
        var diag = Diag{};
        try std.testing.expectError(error.BadIr, t.decodeWithDiag(
            "[{\"add_fact\":{\"schema\":\"ghost\",\"values\":[]}}]",
            &diag,
        ));
        try std.testing.expectEqualStrings("unknown_schema", diag.code.?);
        try std.testing.expectEqualStrings("ghost", t.interner.lookup(diag.symbol.?));
    }

    // add_fact value typed wrong: a quoted "0.05" where the float field
    // wants a JSON number — the other driver failure mode.
    {
        var t = TestSetup.init();
        defer t.deinit();
        var diag = Diag{};
        const source =
            \\[
            \\ {"add_schema":{"name":"param","fields":[["name","symbol"],["value","float"]],"key":1}},
            \\ {"add_fact":{"schema":"param","values":["poll_tax_rate","0.05"]}}
            \\]
        ;
        try std.testing.expectError(error.BadIr, t.decodeWithDiag(source, &diag));
        try std.testing.expectEqualStrings("bad_value_type", diag.code.?);
        try std.testing.expectEqualStrings("param", t.interner.lookup(diag.symbol.?));
        try std.testing.expectEqualStrings("value", t.interner.lookup(diag.field.?));
    }

    // Unrecognized op tag names the offending tag.
    {
        var t = TestSetup.init();
        defer t.deinit();
        var diag = Diag{};
        try std.testing.expectError(error.BadIr, t.decodeWithDiag("[{\"bogus\":{}}]", &diag));
        try std.testing.expectEqualStrings("unknown_op", diag.code.?);
        try std.testing.expectEqualStrings("bogus", t.interner.lookup(diag.symbol.?));
    }

    // A missing required key names the key.
    {
        var t = TestSetup.init();
        defer t.deinit();
        var diag = Diag{};
        const source = "[{\"add_rule\":{\"on\":\"e\",\"when\":{\"lit\":true},\"do\":[]}}]"; // no "name"
        try std.testing.expectError(error.BadIr, t.decodeWithDiag(source, &diag));
        try std.testing.expectEqualStrings("missing_field", diag.code.?);
        try std.testing.expectEqualStrings("name", t.interner.lookup(diag.field.?));
    }

    // A caller that never attaches a Diag sees plain BadIr, unchanged.
    {
        var t = TestSetup.init();
        defer t.deinit();
        try std.testing.expectError(error.BadIr, t.decode("[{\"bogus\":{}}]"));
    }
}

test "decodes procedures, begin actions, and lookup exprs" {
    var t = TestSetup.init();
    defer t.deinit();

    const ops = try t.decode(
        \\[
        \\ {"add_procedure":{"name":"pass_statute","layer":"organic","steps":[
        \\   {"name":"introduce","requires":{"exists":{"schema":"seat","key":[{"field":["instance","by"]}]}}},
        \\   {"name":"floor_vote","requires":{"bin":["gt",
        \\     {"lookup":{"schema":"vote","key":[{"field":["instance","id"]}],"field":"yes"}},{"lit":1}]}}
        \\ ]}},
        \\ {"add_rule":{"name":"sponsor","on":"tick.quarter","when":{"lit":true},"do":[
        \\   {"begin":{"procedure":"pass_statute","bill":{"name":"wool_act","by":"baron","via":"pass_statute","ops":[]}}}
        \\ ]}},
        \\ {"remove_procedure":"pass_statute"}
        \\]
    );

    const proc = ops[0].add_procedure;
    try std.testing.expectEqualStrings("organic", t.interner.lookup(proc.layer));
    try std.testing.expectEqual(@as(usize, 2), proc.steps.len);
    try std.testing.expectEqual(@as(?usize, 1), proc.stepIndex(proc.steps[1].name));
    const lk = proc.steps[1].requires.bin.lhs.lookup;
    try std.testing.expectEqualStrings("vote", t.interner.lookup(lk.schema));
    try std.testing.expectEqualStrings("yes", t.interner.lookup(lk.field));
    try std.testing.expectEqual(@as(usize, 1), lk.key.len);

    const begin = ops[1].add_rule.do[0].begin;
    try std.testing.expectEqual(proc.name, begin.procedure);
    try std.testing.expectEqualStrings("wool_act", t.interner.lookup(begin.bill.name));

    try std.testing.expectEqual(proc.name, ops[2].remove_procedure);
}

test "rejects malformed procedures" {
    const cases = [_][]const u8{
        // zero steps
        "[{\"add_procedure\":{\"name\":\"p\",\"steps\":[]}}]",
        // duplicate step names
        \\[{"add_procedure":{"name":"p","steps":[
        \\  {"name":"a","requires":{"lit":true}},
        \\  {"name":"a","requires":{"lit":true}}
        \\]}}]
        ,
        // step missing requires
        "[{\"add_procedure\":{\"name\":\"p\",\"steps\":[{\"name\":\"a\"}]}}]",
        // lookup missing field
        "[{\"add_rule\":{\"name\":\"r\",\"on\":\"e\",\"when\":{\"lookup\":{\"schema\":\"s\",\"key\":[]}},\"do\":[]}}]",
    };
    for (cases) |case| {
        var t = TestSetup.init();
        defer t.deinit();
        try std.testing.expectError(error.BadIr, t.decode(case));
    }
}
