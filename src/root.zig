//! Zebry — Niri smart screenshot assistant library.
//!
//! Provides programmatic access to:
//! - Niri IPC (window layout, workspace, output info)
//! - AT-SPI2 (accessibility tree, UI element geometry)
//! - Merged smart output (viewport-clipped, scale-corrected, CSD-aware)

const std = @import("std");

pub const niri = struct {
    pub const Client = @import("niri/client.zig").Client;
    pub const types = @import("niri/types.zig");
};

pub const atspi = struct {
    pub const Bindings = @import("atspi/bindings.zig").Bindings;
};

pub const MergeEngine = @import("merge.zig").MergeEngine;
pub const Output = @import("output.zig").Output;

test {
    std.testing.refAllDecls(@import("merge.zig"));
    std.testing.refAllDecls(@import("atspi/bindings.zig"));
    std.testing.refAllDecls(@import("niri/client.zig"));
}

test "rect intersection" {
    const Rect = niri.types.Rect;

    // Overlapping rectangles
    const a: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const b: Rect = .{ .x = 50, .y = 50, .width = 100, .height = 100 };
    const result = Rect.intersect(a, b).?;
    try std.testing.expectEqual(@as(i32, 50), result.x);
    try std.testing.expectEqual(@as(i32, 50), result.y);
    try std.testing.expectEqual(@as(u32, 50), result.width);
    try std.testing.expectEqual(@as(u32, 50), result.height);

    // Non-overlapping rectangles
    const c: Rect = .{ .x = 200, .y = 200, .width = 50, .height = 50 };
    try std.testing.expectEqual(@as(?Rect, null), Rect.intersect(a, c));
}

test "rect scale" {
    const Rect = niri.types.Rect;
    const r: Rect = .{ .x = 100, .y = 50, .width = 800, .height = 600 };
    const scaled = r.scale(1.25);
    try std.testing.expectEqual(@as(i32, 125), scaled.x);
    try std.testing.expectEqual(@as(i32, 62), scaled.y);
    try std.testing.expectEqual(@as(u32, 1000), scaled.width);
    try std.testing.expectEqual(@as(u32, 750), scaled.height);
}
