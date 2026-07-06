//! Rule-body interpreter. Total by construction: every expression node and
//! action burns fuel, comprehensions only iterate finite fact tables, and
//! there is no recursion in the IR a rule can express. Execution stages
//! updates/events into the Ctx; the caller flushes them only on success, so
//! a failing rule is atomic — nothing it staged is observable (§10).

const std = @import("std");
const ir = @import("ir.zig");
const store_mod = @import("store.zig");
const value_mod = @import("value.zig");

pub const Symbol = ir.Symbol;
pub const Value = value_mod.Value;

pub const Event = struct { name: Symbol, args: []const Value };

pub const EvalError = error{
    OutOfFuel,
    TypeMismatch,
    UnboundVar,
    UnknownField,
    DivByZero,
    MissingParam,
    OutOfMemory,
} || store_mod.StoreError;

const Binding = struct { name: Symbol, schema: Symbol, row: []const Value };

const max_env_depth = 8;

pub const Ctx = struct {
    /// Tick arena: staged data lives here and dies at the tick boundary.
    ta: std.mem.Allocator,
    store: *store_mod.FactStore,
    /// Interned "param" — the schema `param` expressions look up.
    param_schema: Symbol,
    fuel: u32,
    priority: i32,
    /// World's monotonic seq counter; advances even for failed rules,
    /// which is fine — the advance itself is deterministic.
    next_seq: *u64,
    env: [max_env_depth]Binding = undefined,
    env_len: usize = 0,
    staged_updates: std.ArrayList(store_mod.QueuedUpdate) = .empty,
    staged_events: std.ArrayList(Event) = .empty,
};

fn burn(ctx: *Ctx) EvalError!void {
    if (ctx.fuel == 0) return error.OutOfFuel;
    ctx.fuel -= 1;
}

pub fn eval(ctx: *Ctx, expr: *const ir.Expr) EvalError!Value {
    try burn(ctx);
    switch (expr.*) {
        .lit => |v| return v,
        .field => |f| {
            const binding = lookupBinding(ctx, f.row_var) orelse return error.UnboundVar;
            const schema = ctx.store.schemas.get(binding.schema) orelse return error.UnknownSchema;
            const fi = schema.fieldIndex(f.field_name) orelse return error.UnknownField;
            return binding.row[fi];
        },
        .param => |name| {
            const row = ctx.store.get(ctx.param_schema, &.{.{ .symbol = name }}) orelse return error.MissingParam;
            return row[1];
        },
        .bin => |b| return evalBin(ctx, b),
        .not => |inner| {
            const v = try eval(ctx, inner);
            if (v != .boolean) return error.TypeMismatch;
            return .{ .boolean = !v.boolean };
        },
    }
}

fn evalBin(ctx: *Ctx, b: ir.Expr.Bin) EvalError!Value {
    const lhs = try eval(ctx, b.lhs);
    const rhs = try eval(ctx, b.rhs);
    switch (b.op) {
        .add, .sub, .mul, .div => return evalArith(b.op, lhs, rhs),
        .lt, .gt => {
            const ord = try numericOrder(lhs, rhs);
            return .{ .boolean = if (b.op == .lt) ord == .lt else ord == .gt };
        },
        .eq => {
            if (std.meta.activeTag(lhs) == std.meta.activeTag(rhs)) return .{ .boolean = lhs.eql(rhs) };
            const ord = try numericOrder(lhs, rhs);
            return .{ .boolean = ord == .eq };
        },
        .@"and", .@"or" => {
            if (lhs != .boolean or rhs != .boolean) return error.TypeMismatch;
            return .{ .boolean = if (b.op == .@"and") lhs.boolean and rhs.boolean else lhs.boolean or rhs.boolean };
        },
    }
}

/// int op int stays int; any float promotes both to float.
fn evalArith(op: ir.BinOp, lhs: Value, rhs: Value) EvalError!Value {
    if (lhs == .int and rhs == .int) {
        const a = lhs.int;
        const b = rhs.int;
        return switch (op) {
            .add => .{ .int = a +% b },
            .sub => .{ .int = a -% b },
            .mul => .{ .int = a *% b },
            .div => if (b == 0) error.DivByZero else .{ .int = @divTrunc(a, b) },
            else => unreachable,
        };
    }
    const a = try toFloat(lhs);
    const b = try toFloat(rhs);
    return switch (op) {
        .add => .{ .float = a + b },
        .sub => .{ .float = a - b },
        .mul => .{ .float = a * b },
        .div => if (b == 0) error.DivByZero else .{ .float = a / b },
        else => unreachable,
    };
}

fn numericOrder(lhs: Value, rhs: Value) EvalError!std.math.Order {
    if (lhs == .int and rhs == .int) return std.math.order(lhs.int, rhs.int);
    return std.math.order(try toFloat(lhs), try toFloat(rhs));
}

fn toFloat(v: Value) EvalError!f64 {
    return switch (v) {
        .float => |f| f,
        .int => |i| @floatFromInt(i),
        else => error.TypeMismatch,
    };
}

fn lookupBinding(ctx: *Ctx, name: Symbol) ?*const Binding {
    var i = ctx.env_len;
    while (i > 0) {
        i -= 1;
        if (ctx.env[i].name == name) return &ctx.env[i];
    }
    return null;
}

pub fn execActions(ctx: *Ctx, actions: []const ir.Action) EvalError!void {
    for (actions) |action| {
        try burn(ctx);
        switch (action) {
            .emit => |e| {
                const args = try ctx.ta.alloc(Value, e.args.len);
                for (e.args, 0..) |*arg, i| args[i] = try eval(ctx, arg);
                try ctx.staged_events.append(ctx.ta, .{ .name = e.event, .args = args });
            },
            .update => |u| {
                const key = try ctx.ta.alloc(Value, u.key.len);
                for (u.key, 0..) |*k, i| key[i] = try eval(ctx, k);
                const raw = try eval(ctx, u.value);
                const vu = try ctx.store.validateUpdate(u.schema, u.field, raw);
                ctx.next_seq.* += 1;
                try ctx.staged_updates.append(ctx.ta, .{
                    .schema = u.schema,
                    .key = key,
                    .field_index = vu.field_index,
                    .op = u.op,
                    .value = vu.value,
                    .priority = ctx.priority,
                    .seq = ctx.next_seq.*,
                });
            },
            .foreach => |f| {
                if (ctx.env_len == max_env_depth) return error.OutOfMemory;
                // Safe to iterate live rows: ACT stages writes, never mutates.
                for (ctx.store.rows(f.schema)) |row| {
                    ctx.env[ctx.env_len] = .{ .name = f.bind, .schema = f.schema, .row = row };
                    ctx.env_len += 1;
                    defer ctx.env_len -= 1;
                    try execActions(ctx, f.body);
                }
            },
        }
    }
}

/// Evaluates the rule's condition and, if it holds, executes its actions.
/// Returns whether the rule fired. Errors leave staged lists populated —
/// the caller must discard them (they live in the tick arena regardless).
pub fn runRule(ctx: *Ctx, rule: *const ir.Rule) EvalError!bool {
    const cond = try eval(ctx, rule.when);
    if (cond != .boolean) return error.TypeMismatch;
    if (!cond.boolean) return false;
    try execActions(ctx, rule.do);
    return true;
}

const testing = std.testing;
const intern = @import("intern.zig");

const TestRig = struct {
    arena: std.heap.ArenaAllocator,
    interner: intern.Interner = .{},
    store: store_mod.FactStore = .{},
    seq: u64 = 0,
    population: Symbol = undefined,
    approval: Symbol = undefined,
    param: Symbol = undefined,

    fn init() !TestRig {
        var rig = TestRig{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
        errdefer rig.deinit();
        const a = rig.arena.allocator();
        rig.population = try rig.sym("population");
        rig.approval = try rig.sym("approval");
        rig.param = try rig.sym("param");
        try rig.store.addSchema(a, .{ .name = rig.population, .key_len = 1, .fields = try a.dupe(ir.Field, &.{
            .{ .name = try rig.sym("bloc"), .ty = .symbol },
            .{ .name = try rig.sym("count"), .ty = .int },
        }) });
        try rig.store.addSchema(a, .{ .name = rig.approval, .key_len = 1, .fields = try a.dupe(ir.Field, &.{
            .{ .name = try rig.sym("bloc"), .ty = .symbol },
            .{ .name = try rig.sym("value"), .ty = .float },
        }) });
        try rig.store.addSchema(a, .{ .name = rig.param, .key_len = 1, .fields = try a.dupe(ir.Field, &.{
            .{ .name = try rig.sym("name"), .ty = .symbol },
            .{ .name = try rig.sym("value"), .ty = .float },
        }) });
        try rig.store.insert(a, rig.population, &.{ .{ .symbol = try rig.sym("north") }, .{ .int = 1000 } });
        try rig.store.insert(a, rig.population, &.{ .{ .symbol = try rig.sym("south") }, .{ .int = 800 } });
        try rig.store.insert(a, rig.approval, &.{ .{ .symbol = try rig.sym("north") }, .{ .float = 0.6 } });
        try rig.store.insert(a, rig.approval, &.{ .{ .symbol = try rig.sym("south") }, .{ .float = 0.5 } });
        try rig.store.insert(a, rig.param, &.{ .{ .symbol = try rig.sym("rate") }, .{ .float = 0.1 } });
        return rig;
    }

    fn deinit(self: *TestRig) void {
        self.interner.deinit(testing.allocator);
        self.arena.deinit();
    }

    fn sym(self: *TestRig, s: []const u8) !Symbol {
        return self.interner.intern(testing.allocator, s);
    }

    fn ctx(self: *TestRig, fuel: u32) Ctx {
        return .{
            .ta = self.arena.allocator(),
            .store = &self.store,
            .param_schema = self.param,
            .fuel = fuel,
            .priority = 0,
            .next_seq = &self.seq,
        };
    }
};

fn lit(v: Value) ir.Expr {
    return .{ .lit = v };
}

test "arithmetic, promotion, comparison, param lookup" {
    var rig = try TestRig.init();
    defer rig.deinit();
    var c = rig.ctx(1000);

    const two = lit(.{ .int = 2 });
    const half = lit(.{ .float = 0.5 });
    const mul = ir.Expr{ .bin = .{ .op = .mul, .lhs = &two, .rhs = &half } };
    try testing.expectEqual(Value{ .float = 1.0 }, try eval(&c, &mul));

    const cmp = ir.Expr{ .bin = .{ .op = .lt, .lhs = &two, .rhs = &half } };
    try testing.expectEqual(Value{ .boolean = false }, try eval(&c, &cmp));

    const p = ir.Expr{ .param = try rig.sym("rate") };
    try testing.expectEqual(Value{ .float = 0.1 }, try eval(&c, &p));

    const missing = ir.Expr{ .param = try rig.sym("nope") };
    try testing.expectError(error.MissingParam, eval(&c, &missing));

    const zero = lit(.{ .int = 0 });
    const div = ir.Expr{ .bin = .{ .op = .div, .lhs = &two, .rhs = &zero } };
    try testing.expectError(error.DivByZero, eval(&c, &div));
}

test "foreach stages one update per row with increasing seq" {
    var rig = try TestRig.init();
    defer rig.deinit();
    var c = rig.ctx(1000);

    const val = lit(.{ .float = -0.01 });
    const key_expr = ir.Expr{ .field = .{ .row_var = try rig.sym("p"), .field_name = try rig.sym("bloc") } };
    const update = ir.Action{ .update = .{
        .schema = rig.approval,
        .key = &.{key_expr},
        .field = try rig.sym("value"),
        .op = .add,
        .value = &val,
    } };
    const foreach = ir.Action{ .foreach = .{
        .schema = rig.population,
        .bind = try rig.sym("p"),
        .body = &.{update},
    } };

    try execActions(&c, &.{foreach});
    try testing.expectEqual(@as(usize, 2), c.staged_updates.items.len);
    try testing.expect(c.staged_updates.items[0].seq < c.staged_updates.items[1].seq);
    // Nothing reaches the store until the caller flushes.
    try testing.expectEqual(@as(usize, 0), rig.store.queued.items.len);
}

test "fuel exhaustion errors and when:false does not fire" {
    var rig = try TestRig.init();
    defer rig.deinit();

    const t = lit(.{ .boolean = true });
    const f = lit(.{ .boolean = false });
    const emit = ir.Action{ .emit = .{ .event = try rig.sym("ping"), .args = &.{} } };

    var starved = rig.ctx(1);
    const rule = ir.Rule{ .name = try rig.sym("r"), .on = try rig.sym("e"), .priority = 0, .when = &t, .do = &.{ emit, emit } };
    try testing.expectError(error.OutOfFuel, runRule(&starved, &rule));

    var fine = rig.ctx(1000);
    const silent = ir.Rule{ .name = rule.name, .on = rule.on, .priority = 0, .when = &f, .do = &.{emit} };
    try testing.expectEqual(false, try runRule(&fine, &silent));
    try testing.expectEqual(@as(usize, 0), fine.staged_events.items.len);
}
