const std = @import("std");
const merge = @import("merge.zig");
const niri_types = @import("niri/types.zig");

/// JSON output serializer for zebry data.
/// Directly streams formatted JSON to any provided writer (such as stdout).
pub const Output = struct {
    /// Serialize SmartOutput to JSON.
    pub fn writeSmartOutput(writer: anytype, data: merge.SmartOutput) !void {
        try writer.writeAll("{\n");

        // focused_window
        try writer.writeAll("  \"focused_window\": ");
        if (data.focused_window) |fw| {
            try writeMergedWindow(writer, fw, 1);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\n");

        // visible_windows
        try writer.writeAll("  \"visible_windows\": ");
        try writeMergedWindowArray(writer, data.visible_windows, 1);
        try writer.writeAll(",\n");

        // all_windows
        try writer.writeAll("  \"all_windows\": ");
        try writeMergedWindowArray(writer, data.all_windows, 1);

        try writer.writeAll("\n}\n");
    }

    /// Serialize a single merged window (for focused command).
    pub fn writeSingleWindow(writer: anytype, win: ?merge.MergedWindow) !void {
        if (win) |w| {
            try writeMergedWindow(writer, w, 0);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll("\n");
    }

    /// Serialize hierarchical regions using the same shape as focused/smart.
    pub fn writeRegions(writer: anytype, regions: []const merge.RegionInfo) !void {
        try writer.writeAll("[");
        for (regions, 0..) |region, i| {
            if (i > 0) try writer.writeAll(",");
            try writeNewline(writer, 1);
            try writeRegion(writer, region, 1);
        }
        if (regions.len > 0) try writeNewline(writer, 0);
        try writer.writeAll("]\n");
    }

    /// Serialize niri windows (raw, no merge).
    pub fn writeNiriWindows(writer: anytype, windows: []const niri_types.Window) !void {
        try writer.writeAll("[\n");
        for (windows, 0..) |win, i| {
            if (i > 0) try writer.writeAll(",\n");
            try writeNiriWindow(writer, win, 1);
        }
        try writer.writeAll("\n]\n");
    }

    /// Stream PID-selected windows without copying their root regions.
    pub fn writeWindowRegions(writer: anytype, windows: []const merge.MergedWindow) !void {
        try writer.writeByte('[');
        var first = true;
        for (windows) |window| {
            for (window.regions) |region| {
                if (!first) try writer.writeByte(',');
                first = false;
                try writeNewline(writer, 1);
                try writeRegion(writer, region, 1);
            }
        }
        if (!first) try writeNewline(writer, 0);
        try writer.writeAll("]\n");
    }

    // ─────────────── Internal writers ───────────────

    fn writeMergedWindowArray(writer: anytype, windows: []merge.MergedWindow, indent: u32) !void {
        try writer.writeAll("[");
        for (windows, 0..) |win, i| {
            if (i > 0) try writer.writeAll(",");
            try writeNewline(writer, indent + 1);
            try writeMergedWindow(writer, win, indent + 1);
        }
        if (windows.len > 0) try writeNewline(writer, indent);
        try writer.writeAll("]");
    }

    fn writeMergedWindow(writer: anytype, win: merge.MergedWindow, indent: u32) !void {
        try writer.writeAll("{");
        try writeNewline(writer, indent + 1);

        try writeKvInt(writer, "id", @intCast(win.id));
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);

        try writeKvOptStr(writer, "title", win.title);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);

        try writeKvOptStr(writer, "app_id", win.app_id);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);

        try writeKvOptInt(writer, "pid", win.pid);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);

        try writeKvOptInt(writer, "workspace_id", if (win.workspace_id) |wid| @as(i64, @intCast(wid)) else null);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);

        try writeKvBool(writer, "is_focused", win.is_focused);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);

        try writeKvBool(writer, "is_floating", win.is_floating);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);

        try writeKvBool(writer, "visible", win.visible);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);

        try writeKvBool(writer, "atspi_available", win.atspi_available);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);
        try writeKvBool(writer, "regions_truncated", win.regions_truncated);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);

        try writeKvStr(writer, "region_source", win.region_source);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);

        try writeKvBool(writer, "bounds_estimated", win.bounds_estimated);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);

        try writeKvOptStr(writer, "output", win.output_name);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);

        // Geometry
        try writer.writeAll("\"geometry\": ");
        try writeCoordPair(writer, win.window_geometry);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);

        // Visible geometry (clipped)
        try writer.writeAll("\"visible_geometry\": ");
        if (win.visible_geometry) |vg| {
            try writeCoordPair(writer, vg);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);

        // Shadow offset
        try writer.print("\"shadow\": {{\"left\": {d:.1}, \"top\": {d:.1}, \"right\": {d:.1}, \"bottom\": {d:.1}}}", .{
            win.shadow_offset.left,
            win.shadow_offset.top,
            win.shadow_offset.right,
            win.shadow_offset.bottom,
        });
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);

        // Regions
        try writer.writeAll("\"regions\": [");
        for (win.regions, 0..) |region, i| {
            if (i > 0) try writer.writeAll(",");
            try writeNewline(writer, indent + 2);
            try writeRegion(writer, region, indent + 2);
        }
        if (win.regions.len > 0) try writeNewline(writer, indent + 1);
        try writer.writeAll("]");

        try writeNewline(writer, indent);
        try writer.writeAll("}");
    }

    fn writeCoordPair(writer: anytype, cp: merge.CoordPair) !void {
        try writer.print("{{\"logical\": {{\"x\": {d}, \"y\": {d}, \"width\": {d}, \"height\": {d}}}, \"physical\": {{\"x\": {d}, \"y\": {d}, \"width\": {d}, \"height\": {d}}}, \"scale\": {d:.2}}}", .{
            cp.logical.x,
            cp.logical.y,
            cp.logical.width,
            cp.logical.height,
            cp.physical.x,
            cp.physical.y,
            cp.physical.width,
            cp.physical.height,
            cp.scale,
        });
    }

    fn writeRegion(writer: anytype, region: merge.RegionInfo, indent: u32) !void {
        try writer.writeAll("{");
        try writeNewline(writer, indent + 1);
        try writeKvOptStr(writer, "name", region.name);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);
        try writeKvStr(writer, "role", region.role);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);
        try writer.writeAll("\"bounds\": ");
        try writeCoordPair(writer, region.bounds);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);
        try writer.writeAll("\"children\": [");
        for (region.children, 0..) |child, i| {
            if (i > 0) try writer.writeAll(",");
            try writeNewline(writer, indent + 2);
            try writeRegion(writer, child, indent + 2);
        }
        if (region.children.len > 0) try writeNewline(writer, indent + 1);
        try writer.writeAll("]");
        try writeNewline(writer, indent);
        try writer.writeAll("}");
    }

    fn writeNiriWindow(writer: anytype, win: niri_types.Window, indent: u32) !void {
        try writer.writeAll("  {");
        try writeNewline(writer, indent + 1);
        try writeKvInt(writer, "id", @intCast(win.id));
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);
        try writeKvOptStr(writer, "title", win.title);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);
        try writeKvOptStr(writer, "app_id", win.app_id);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);
        try writeKvOptInt(writer, "pid", win.pid);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);
        try writeKvBool(writer, "is_focused", win.is_focused);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);
        try writeKvBool(writer, "is_floating", win.is_floating);
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);
        try writer.print("\"window_size\": [{d}, {d}]", .{ win.layout.window_size[0], win.layout.window_size[1] });
        try writer.writeAll(",");
        try writeNewline(writer, indent + 1);
        try writer.print("\"tile_size\": [{d:.1}, {d:.1}]", .{ win.layout.tile_size[0], win.layout.tile_size[1] });
        try writeNewline(writer, indent);
        try writer.writeAll("}");
    }

    // ─────────────── Primitive writers ───────────────

    fn writeNewline(writer: anytype, indent: u32) !void {
        try writer.writeAll("\n");
        for (0..indent) |_| {
            try writer.writeAll("  ");
        }
    }

    fn writeKvStr(writer: anytype, key: []const u8, value: []const u8) !void {
        try writer.print("\"{s}\": ", .{key});
        try writeJsonString(writer, value);
    }

    fn writeKvOptStr(writer: anytype, key: []const u8, value: ?[]const u8) !void {
        try writer.print("\"{s}\": ", .{key});
        if (value) |v| {
            try writeJsonString(writer, v);
        } else {
            try writer.writeAll("null");
        }
    }

    fn writeKvInt(writer: anytype, key: []const u8, value: i64) !void {
        try writer.print("\"{s}\": {d}", .{ key, value });
    }

    fn writeKvOptInt(writer: anytype, key: []const u8, value: anytype) !void {
        try writer.print("\"{s}\": ", .{key});
        if (value) |v| {
            try writer.print("{d}", .{v});
        } else {
            try writer.writeAll("null");
        }
    }

    fn writeKvBool(writer: anytype, key: []const u8, value: bool) !void {
        try writer.print("\"{s}\": {s}", .{ key, if (value) "true" else "false" });
    }
};

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeAll("\"");
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try writer.print("\\u{x:0>4}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
    try writer.writeAll("\"");
}
