//! politick kernel library. See docs/dsl-sketch.md for the design.

const std = @import("std");

pub const intern = @import("intern.zig");
pub const value = @import("value.zig");
pub const hash = @import("hash.zig");
pub const log = @import("log.zig");
pub const tick = @import("tick.zig");

test {
    std.testing.refAllDecls(@This());
}
