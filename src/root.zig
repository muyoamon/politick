//! politick kernel library. See docs/dsl-sketch.md for the design.

const std = @import("std");

pub const intern = @import("intern.zig");
pub const value = @import("value.zig");
pub const hash = @import("hash.zig");
pub const log = @import("log.zig");
pub const ir = @import("ir.zig");
pub const store = @import("store.zig");
pub const interp = @import("interp.zig");
pub const derive = @import("derive.zig");
pub const check = @import("check.zig");
pub const tick = @import("tick.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("golden_test.zig");
    _ = @import("commit_test.zig");
    _ = @import("procedure_test.zig");
}
