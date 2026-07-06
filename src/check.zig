//! Static reference/type checking for diffs at COMMIT (§9): added rules and
//! metas must resolve every schema, field, and binding against the
//! post-diff state; removed schemas must not be referenced by any surviving
//! term. Validation is the only place diffs fail — apply is total.

const std = @import("std");
const ir = @import("ir.zig");

pub const Symbol = ir.Symbol;

pub const CheckError = error{
    UnknownSchema,
    UnknownField,
    UnboundVar,
    KeyFieldUpdate,
    ArityMismatch,
    OutOfMemory,
};

/// The schema set as it would look after the diff applies.
pub const SchemaView = struct {
    base: *const std.AutoArrayHashMapUnmanaged(Symbol, ir.Schema),
    removed: []const Symbol = &.{},
    added: []const ir.Schema = &.{},

    pub fn get(self: SchemaView, name: Symbol) ?ir.Schema {
        for (self.added) |s| {
            if (s.name == name) return s;
        }
        for (self.removed) |r| {
            if (r == name) return null;
        }
        return self.base.get(name);
    }
};

pub const Binding = struct { name: Symbol, schema: Symbol };

pub const Ctx = struct {
    view: SchemaView,
    /// Interned "param" — what `param` expressions implicitly reference.
    param_schema: Symbol,
    /// Pre-bound row vars, e.g. `diff` → staged_diff for meta allow exprs.
    prebound: []const Binding = &.{},
};

const max_env_depth = 8;

const Env = struct {
    stack: [max_env_depth]Binding = undefined,
    len: usize = 0,

    fn lookup(self: *const Env, name: Symbol) ?Symbol {
        var i = self.len;
        while (i > 0) {
            i -= 1;
            if (self.stack[i].name == name) return self.stack[i].schema;
        }
        return null;
    }
};

pub fn checkRule(ctx: *const Ctx, rule: ir.Rule) CheckError!void {
    var env = try preboundEnv(ctx);
    try checkExpr(ctx, &env, rule.when);
    try checkActions(ctx, &env, rule.do);
}

pub fn checkMetaAllow(ctx: *const Ctx, meta: ir.Meta) CheckError!void {
    var env = try preboundEnv(ctx);
    try checkExpr(ctx, &env, meta.allow);
}

/// Checks every step's `requires`; the ctx should prebind `instance` →
/// proc_instance, the row the kernel injects at each advance evaluation.
pub fn checkProcedure(ctx: *const Ctx, proc: ir.Procedure) CheckError!void {
    for (proc.steps) |step| {
        var env = try preboundEnv(ctx);
        try checkExpr(ctx, &env, step.requires);
    }
}

fn preboundEnv(ctx: *const Ctx) CheckError!Env {
    var env = Env{};
    for (ctx.prebound) |b| {
        env.stack[env.len] = b;
        env.len += 1;
    }
    return env;
}

fn checkExpr(ctx: *const Ctx, env: *Env, expr: *const ir.Expr) CheckError!void {
    switch (expr.*) {
        .lit => {},
        .field => |f| {
            const schema_sym = env.lookup(f.row_var) orelse return error.UnboundVar;
            const schema = ctx.view.get(schema_sym) orelse return error.UnknownSchema;
            if (schema.fieldIndex(f.field_name) == null) return error.UnknownField;
        },
        .param => {
            if (ctx.view.get(ctx.param_schema) == null) return error.UnknownSchema;
        },
        .bin => |b| {
            try checkExpr(ctx, env, b.lhs);
            try checkExpr(ctx, env, b.rhs);
        },
        .not => |inner| try checkExpr(ctx, env, inner),
        .exists => |e| {
            const schema = ctx.view.get(e.schema) orelse return error.UnknownSchema;
            if (e.key.len != schema.key_len) return error.ArityMismatch;
            for (e.key) |*k| try checkExpr(ctx, env, k);
        },
        .lookup => |l| {
            const schema = ctx.view.get(l.schema) orelse return error.UnknownSchema;
            if (l.key.len != schema.key_len) return error.ArityMismatch;
            if (schema.fieldIndex(l.field) == null) return error.UnknownField;
            for (l.key) |*k| try checkExpr(ctx, env, k);
        },
    }
}

fn checkActions(ctx: *const Ctx, env: *Env, actions: []const ir.Action) CheckError!void {
    for (actions) |action| {
        switch (action) {
            .emit => |e| for (e.args) |*arg| try checkExpr(ctx, env, arg),
            .update => |u| {
                const schema = ctx.view.get(u.schema) orelse return error.UnknownSchema;
                if (u.key.len != schema.key_len) return error.ArityMismatch;
                const fi = schema.fieldIndex(u.field) orelse return error.UnknownField;
                if (fi < schema.key_len) return error.KeyFieldUpdate;
                for (u.key) |*k| try checkExpr(ctx, env, k);
                try checkExpr(ctx, env, u.value);
            },
            .foreach => |f| {
                if (ctx.view.get(f.schema) == null) return error.UnknownSchema;
                if (env.len == max_env_depth) return error.OutOfMemory;
                env.stack[env.len] = .{ .name = f.bind, .schema = f.schema };
                env.len += 1;
                defer env.len -= 1;
                try checkActions(ctx, env, f.body);
            },
            // Validated when the embedded diff itself commits; a begin's
            // procedure resolves at fire time (§2.4), never statically.
            .stage, .begin => {},
        }
    }
}

/// Does this rule reference the schema (for removal closure checks)?
/// `param` exprs implicitly reference the param schema. Embedded staged
/// diffs don't count: they get their own COMMIT validation.
pub fn ruleRefersToSchema(rule: ir.Rule, target: Symbol, param_schema: Symbol) bool {
    return exprRefs(rule.when, target, param_schema) or actionsRef(rule.do, target, param_schema);
}

pub fn metaRefersToSchema(meta: ir.Meta, target: Symbol, param_schema: Symbol) bool {
    return exprRefs(meta.allow, target, param_schema);
}

pub fn procedureRefersToSchema(proc: ir.Procedure, target: Symbol, param_schema: Symbol) bool {
    for (proc.steps) |step| {
        if (exprRefs(step.requires, target, param_schema)) return true;
    }
    return false;
}

fn exprRefs(expr: *const ir.Expr, target: Symbol, param_schema: Symbol) bool {
    return switch (expr.*) {
        .lit, .field => false,
        .param => target == param_schema,
        .bin => |b| exprRefs(b.lhs, target, param_schema) or exprRefs(b.rhs, target, param_schema),
        .not => |inner| exprRefs(inner, target, param_schema),
        .exists => |e| e.schema == target or blk: {
            for (e.key) |*k| {
                if (exprRefs(k, target, param_schema)) break :blk true;
            }
            break :blk false;
        },
        .lookup => |l| l.schema == target or blk: {
            for (l.key) |*k| {
                if (exprRefs(k, target, param_schema)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn actionsRef(actions: []const ir.Action, target: Symbol, param_schema: Symbol) bool {
    for (actions) |action| {
        const hit = switch (action) {
            .emit => |e| blk: {
                for (e.args) |*arg| {
                    if (exprRefs(arg, target, param_schema)) break :blk true;
                }
                break :blk false;
            },
            .update => |u| u.schema == target or exprRefs(u.value, target, param_schema) or blk: {
                for (u.key) |*k| {
                    if (exprRefs(k, target, param_schema)) break :blk true;
                }
                break :blk false;
            },
            .foreach => |f| f.schema == target or actionsRef(f.body, target, param_schema),
            .stage, .begin => false,
        };
        if (hit) return true;
    }
    return false;
}

const testing = std.testing;
const intern = @import("intern.zig");

const TestSetup = struct {
    arena: std.heap.ArenaAllocator,
    interner: intern.Interner = .{},
    schemas: std.AutoArrayHashMapUnmanaged(Symbol, ir.Schema) = .empty,

    fn init() TestSetup {
        return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(self: *TestSetup) void {
        self.interner.deinit(testing.allocator);
        self.arena.deinit();
    }

    fn sym(self: *TestSetup, s: []const u8) !Symbol {
        return self.interner.intern(testing.allocator, s);
    }

    fn addSchema(self: *TestSetup, name: []const u8, fields: []const struct { []const u8, ir.FieldType }, key_len: u8) !Symbol {
        const a = self.arena.allocator();
        const fs = try a.alloc(ir.Field, fields.len);
        for (fields, 0..) |f, i| {
            fs[i] = .{ .name = try self.sym(f.@"0"), .ty = f.@"1" };
        }
        const n = try self.sym(name);
        try self.schemas.put(a, n, .{ .name = n, .fields = fs, .key_len = key_len, .layer = try self.sym("statute") });
        return n;
    }
};

test "checkRule resolves foreach bindings; dangling refs fail" {
    var t = TestSetup.init();
    defer t.deinit();
    const population = try t.addSchema("population", &.{ .{ "bloc", .symbol }, .{ "count", .int } }, 1);
    const ctx = Ctx{
        .view = .{ .base = &t.schemas },
        .param_schema = try t.sym("param"),
    };

    const tru = ir.Expr{ .lit = .{ .boolean = true } };
    const count_ref = ir.Expr{ .field = .{ .row_var = try t.sym("p"), .field_name = try t.sym("count") } };
    const bad_field = ir.Expr{ .field = .{ .row_var = try t.sym("p"), .field_name = try t.sym("nope") } };
    const key_ref = ir.Expr{ .field = .{ .row_var = try t.sym("p"), .field_name = try t.sym("bloc") } };

    const good_update = ir.Action{ .update = .{ .schema = population, .key = &.{key_ref}, .field = try t.sym("count"), .op = .add, .value = &count_ref } };
    const good = ir.Rule{ .name = try t.sym("g"), .on = try t.sym("e"), .priority = 0, .layer = try t.sym("statute"), .when = &tru, .do = &.{
        .{ .foreach = .{ .schema = population, .bind = try t.sym("p"), .body = &.{good_update} } },
    } };
    try checkRule(&ctx, good);

    // Unbound var: field ref outside its foreach.
    const loose = ir.Rule{ .name = good.name, .on = good.on, .priority = 0, .layer = good.layer, .when = &count_ref, .do = &.{} };
    try testing.expectError(error.UnboundVar, checkRule(&ctx, loose));

    // Unknown field inside a valid binding.
    const bad_update = ir.Action{ .update = .{ .schema = population, .key = &.{key_ref}, .field = try t.sym("count"), .op = .add, .value = &bad_field } };
    const dangling = ir.Rule{ .name = good.name, .on = good.on, .priority = 0, .layer = good.layer, .when = &tru, .do = &.{
        .{ .foreach = .{ .schema = population, .bind = try t.sym("p"), .body = &.{bad_update} } },
    } };
    try testing.expectError(error.UnknownField, checkRule(&ctx, dangling));

    // Key fields are immutable.
    const key_update = ir.Action{ .update = .{ .schema = population, .key = &.{key_ref}, .field = try t.sym("bloc"), .op = .set, .value = &count_ref } };
    const key_rule = ir.Rule{ .name = good.name, .on = good.on, .priority = 0, .layer = good.layer, .when = &tru, .do = &.{
        .{ .foreach = .{ .schema = population, .bind = try t.sym("p"), .body = &.{key_update} } },
    } };
    try testing.expectError(error.KeyFieldUpdate, checkRule(&ctx, key_rule));
}

test "SchemaView layers removes and adds over the base" {
    var t = TestSetup.init();
    defer t.deinit();
    const population = try t.addSchema("population", &.{ .{ "bloc", .symbol }, .{ "count", .int } }, 1);

    const replacement = ir.Schema{
        .name = population,
        .fields = &.{.{ .name = try t.sym("bloc"), .ty = .symbol }},
        .key_len = 1,
        .layer = try t.sym("statute"),
    };
    const removed_view = SchemaView{ .base = &t.schemas, .removed = &.{population} };
    const swapped_view = SchemaView{ .base = &t.schemas, .removed = &.{population}, .added = &.{replacement} };

    try testing.expectEqual(@as(?ir.Schema, null), removed_view.get(population));
    try testing.expectEqual(@as(usize, 1), swapped_view.get(population).?.fields.len);
}

test "refersToSchema sees exists, foreach, update, and param refs" {
    var t = TestSetup.init();
    defer t.deinit();
    const office = try t.addSchema("office", &.{ .{ "name", .symbol }, .{ "holder", .symbol } }, 2);
    const param = try t.sym("param");
    const other = try t.sym("other");

    const lit = ir.Expr{ .lit = .{ .boolean = true } };
    const uses_exists = ir.Expr{ .exists = .{ .schema = office, .key = &.{ lit, lit } } };
    const meta = ir.Meta{ .name = try t.sym("m"), .layer = other, .governs_layer = other, .min_staged_ticks = 0, .allow = &uses_exists };
    try testing.expect(metaRefersToSchema(meta, office, param));
    try testing.expect(!metaRefersToSchema(meta, other, param));

    const uses_param = ir.Expr{ .param = try t.sym("rate") };
    const rule = ir.Rule{ .name = try t.sym("r"), .on = other, .priority = 0, .layer = other, .when = &uses_param, .do = &.{} };
    try testing.expect(ruleRefersToSchema(rule, param, param));
    try testing.expect(!ruleRefersToSchema(rule, office, param));
}

test "checkProcedure resolves lookups under the instance prebinding" {
    var t = TestSetup.init();
    defer t.deinit();
    const vote = try t.addSchema("vote", &.{ .{ "bill", .symbol }, .{ "yes", .int } }, 1);
    const proc_instance = try t.addSchema("proc_instance", &.{ .{ "id", .symbol }, .{ "step", .symbol } }, 1);
    const instance = try t.sym("instance");
    const ctx = Ctx{
        .view = .{ .base = &t.schemas },
        .param_schema = try t.sym("param"),
        .prebound = &.{.{ .name = instance, .schema = proc_instance }},
    };

    const id_ref = ir.Expr{ .field = .{ .row_var = instance, .field_name = try t.sym("id") } };
    const yes = try t.sym("yes");
    const tally = ir.Expr{ .lookup = .{ .schema = vote, .key = &.{id_ref}, .field = yes } };
    const good = ir.Procedure{ .name = try t.sym("p"), .layer = try t.sym("organic"), .steps = &.{
        .{ .name = try t.sym("floor_vote"), .requires = &tally },
    } };
    try checkProcedure(&ctx, good);

    // Without the prebinding the instance field ref is unbound.
    const bare = Ctx{ .view = ctx.view, .param_schema = ctx.param_schema };
    try testing.expectError(error.UnboundVar, checkProcedure(&bare, good));

    // Unknown field, wrong key arity, unknown schema.
    const bad_field = ir.Expr{ .lookup = .{ .schema = vote, .key = &.{id_ref}, .field = try t.sym("nope") } };
    const bad_proc = ir.Procedure{ .name = good.name, .layer = good.layer, .steps = &.{
        .{ .name = good.steps[0].name, .requires = &bad_field },
    } };
    try testing.expectError(error.UnknownField, checkProcedure(&ctx, bad_proc));

    const bad_arity = ir.Expr{ .lookup = .{ .schema = vote, .key = &.{ id_ref, id_ref }, .field = yes } };
    const arity_proc = ir.Procedure{ .name = good.name, .layer = good.layer, .steps = &.{
        .{ .name = good.steps[0].name, .requires = &bad_arity },
    } };
    try testing.expectError(error.ArityMismatch, checkProcedure(&ctx, arity_proc));

    // Removal closure sees refs through lookup exprs.
    try testing.expect(procedureRefersToSchema(good, vote, ctx.param_schema));
    try testing.expect(!procedureRefersToSchema(good, proc_instance, ctx.param_schema));
}
