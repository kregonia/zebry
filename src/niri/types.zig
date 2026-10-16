const std = @import("std");

/// Niri IPC data types — mirrors niri-ipc/src/lib.rs
/// All fields use Zig-idiomatic naming; JSON parsing uses serde-compatible field names.

// ─────────────────────────── Timestamp ───────────────────────────

pub const Timestamp = struct {
    secs: u64,
    nanos: u32,
};

// ─────────────────────────── Window ─────────────────────────────

pub const WindowLayout = struct {
    pos_in_scrolling_layout: ?struct { usize, usize } = null,
    tile_size: struct { f64, f64 },
    window_size: struct { i32, i32 },
    tile_pos_in_workspace_view: ?struct { f64, f64 } = null,
    window_offset_in_tile: struct { f64, f64 },
};

pub const Window = struct {
    id: u64,
    title: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    pid: ?i32 = null,
    workspace_id: ?u64 = null,
    is_focused: bool,
    is_floating: bool,
    is_urgent: bool,
    layout: WindowLayout,
    focus_timestamp: ?Timestamp = null,
};

// ─────────────────────────── Output ─────────────────────────────

pub const OutputMode = struct {
    width: u32,
    height: u32,
    refresh_rate: u32,
    is_preferred: bool,
};

pub const LogicalOutput = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    scale: f64,
    transform: []const u8 = "Normal",
};

pub const Output = struct {
    name: []const u8,
    make: []const u8 = "",
    model: []const u8 = "",
    serial: ?[]const u8 = null,
    physical_size: ?struct { u32, u32 } = null,
    modes: []const OutputMode = &.{},
    current_mode: ?u32 = null,
    is_custom_mode: bool = false,
    vrr_supported: bool = false,
    vrr_enabled: bool = false,
    logical: ?LogicalOutput = null,
};

// ─────────────────────────── Workspace ──────────────────────────

pub const Workspace = struct {
    id: u64,
    idx: u32,
    name: ?[]const u8 = null,
    output: ?[]const u8 = null,
    is_urgent: bool = false,
    is_active: bool = false,
    is_focused: bool = false,
    active_window_id: ?u64 = null,
};

// ─────────────────────────── Geometry helpers ───────────────────

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    /// Compute the intersection of two rectangles.
    /// Returns null if they do not overlap.
    pub fn intersect(a: Rect, b: Rect) ?Rect {
        const left: i32 = @max(a.x, b.x);
        const top: i32 = @max(a.y, b.y);
        const right: i64 = @min(
            @as(i64, a.x) + a.width,
            @as(i64, b.x) + b.width,
        );
        const bottom: i64 = @min(
            @as(i64, a.y) + a.height,
            @as(i64, b.y) + b.height,
        );

        if (right <= left or bottom <= top) return null;

        return .{
            .x = left,
            .y = top,
            .width = @intCast(right - left),
            .height = @intCast(bottom - top),
        };
    }

    /// Scale the rectangle by a given factor (logical → physical).
    pub fn scale(self: Rect, factor: f64) Rect {
        return .{
            .x = @intFromFloat(@as(f64, @floatFromInt(self.x)) * factor),
            .y = @intFromFloat(@as(f64, @floatFromInt(self.y)) * factor),
            .width = @intFromFloat(@as(f64, @floatFromInt(self.width)) * factor),
            .height = @intFromFloat(@as(f64, @floatFromInt(self.height)) * factor),
        };
    }
};
