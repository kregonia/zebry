const std = @import("std");
const niri_types = @import("niri/types.zig");
const niri_client = @import("niri/client.zig");
const atspi = @import("atspi/bindings.zig");

const Allocator = std.mem.Allocator;

// ─────────────────── Output types ──────────────────

pub const CoordPair = struct {
    logical: niri_types.Rect,
    physical: niri_types.Rect,
    scale: f64,
};

pub const RegionInfo = struct {
    name: ?[]const u8,
    role: []const u8,
    bounds: CoordPair,
    children: []RegionInfo = &.{},

    /// Regions own their names and children; role names are static.
    pub fn deinit(self: RegionInfo, allocator: Allocator) void {
        if (self.name) |name| allocator.free(name);
        for (self.children) |child| child.deinit(allocator);
        allocator.free(self.children);
    }
};

pub const MergedWindow = struct {
    // niri fields
    id: u64,
    title: ?[]const u8,
    app_id: ?[]const u8,
    pid: ?i32,
    workspace_id: ?u64,
    is_focused: bool,
    is_floating: bool,
    is_urgent: bool,

    // Geometry
    window_geometry: CoordPair,
    tile_geometry: ?CoordPair,
    visible_geometry: ?CoordPair, // After viewport clipping
    visible: bool,

    // CSD shadow info
    shadow_offset: struct { left: f64, top: f64, right: f64, bottom: f64 },

    // AT-SPI2 enrichment and fallback source
    atspi_available: bool,
    regions_truncated: bool,
    region_source: []const u8,
    bounds_estimated: bool,
    regions: []RegionInfo,

    // Metadata
    output_name: ?[]const u8,
};

pub const SmartOutput = struct {
    focused_window: ?MergedWindow,
    visible_windows: []MergedWindow,
    all_windows: []MergedWindow,
};

pub const Options = struct {
    atspi_enabled: bool = true,
    include_web: bool = false,
    query: atspi.QueryOptions = .{},
};

// ─────────────────── Merge Engine ──────────────────

pub const MergeEngine = struct {
    allocator: Allocator,
    niri: niri_client.Client,
    atspi_bindings: ?atspi.Bindings = null,
    options: Options = .{},

    pub fn init(allocator: Allocator) !MergeEngine {
        return initWithOptions(allocator, .{});
    }

    pub fn initWithOptions(allocator: Allocator, options: Options) !MergeEngine {
        return .{
            .allocator = allocator,
            .niri = try niri_client.Client.init(allocator),
            .options = options,
        };
    }

    pub fn deinit(self: *MergeEngine) void {
        if (self.atspi_bindings) |*ab| {
            ab.deinit();
        }
    }

    /// The core "smart" command — merges niri + AT-SPI2 data.
    pub fn buildSmartOutput(self: *MergeEngine) !SmartOutput {
        return self.buildOutput(null, null, false);
    }

    /// Query only the selected application rather than every accessibility
    /// tree on the desktop. An absent focused window is a valid null result.
    pub fn buildWindowOutput(self: *MergeEngine, window_id: ?u64) !?MergedWindow {
        const result = try self.buildOutput(window_id, null, true);
        defer self.allocator.free(result.all_windows);
        defer self.allocator.free(result.visible_windows);
        return if (result.all_windows.len > 0) result.all_windows[0] else null;
    }

    /// PID-targeted equivalent used by the regions command and scripts that
    /// already know the compositor process id.
    pub fn buildPidOutput(self: *MergeEngine, pid: u32) ![]MergedWindow {
        const result = try self.buildOutput(null, pid, false);
        self.allocator.free(result.visible_windows);
        return result.all_windows;
    }

    fn buildOutput(self: *MergeEngine, window_id: ?u64, target_pid: ?u32, single_window: bool) !SmartOutput {
        // 1. Fetch all data from niri
        const windows = try self.niri.getWindows();
        var target: ?niri_client.Window = null;
        if (single_window or target_pid != null) {
            for (windows) |window| {
                const matches = if (window_id) |id|
                    window.id == id
                else if (target_pid) |pid|
                    matchesPid(window, pid)
                else
                    window.is_focused;
                if (matches) {
                    target = window;
                    break;
                }
            }
            if ((window_id != null or target_pid != null) and target == null) return error.WindowNotFound;
        }
        const outputs = try self.niri.getOutputGeometries();

        // 2. Find the focused output's viewport
        var viewport: ?niri_types.Rect = null;
        var viewport_scale: f64 = 1.0;
        var focused_output_name: ?[]const u8 = null;

        for (outputs) |output| {
            if (output.logical) |logical| {
                // For single-monitor setup or finding active output
                viewport = .{
                    .x = logical.x,
                    .y = logical.y,
                    .width = logical.width,
                    .height = logical.height,
                };
                viewport_scale = logical.scale;
                focused_output_name = output.name;
                break; // TODO: multi-monitor — find the focused output
            }
        }

        // Select before accessibility discovery. Only matched window trees
        // are expanded, and geometry-only requests never initialize AT-SPI.
        var selected: std.ArrayList(niri_client.Window) = .empty;
        defer selected.deinit(self.allocator);
        for (windows) |window| {
            if (single_window and (target == null or window.id != target.?.id)) continue;
            if (target_pid) |pid| if (!matchesPid(window, pid)) continue;
            try selected.append(self.allocator, window);
        }
        if (self.options.atspi_enabled and selected.items.len > 0 and self.atspi_bindings == null) {
            self.atspi_bindings = atspi.Bindings.init(self.allocator) catch null;
        }
        const query_result: ?atspi.QueryResult = if (self.options.atspi_enabled and self.atspi_bindings != null)
            self.atspi_bindings.?.getApplicationsForWindows(selected.items, self.options.query) catch null
        else
            null;
        const atspi_apps = if (query_result) |result| result.apps else null;
        defer if (atspi_apps) |apps| {
            for (apps) |app| app.deinit(self.allocator);
            self.allocator.free(apps);
        };

        // 4. Merge each window
        var merged: std.ArrayList(MergedWindow) = .empty;
        errdefer {
            for (merged.items) |window| freeOwnedRegions(self.allocator, window.regions);
            merged.deinit(self.allocator);
        }

        var focused: ?MergedWindow = null;
        var visible: std.ArrayList(MergedWindow) = .empty;
        errdefer visible.deinit(self.allocator);

        for (selected.items) |win| {
            var merged_win = try self.mergeWindow(win, viewport, viewport_scale, focused_output_name, atspi_apps);
            if (query_result) |result| {
                if ((result.exhausted or result.incomplete) and !merged_win.atspi_available) {
                    merged_win.regions_truncated = true;
                }
            }
            merged.append(self.allocator, merged_win) catch |err| {
                freeOwnedRegions(self.allocator, merged_win.regions);
                return err;
            };

            if (win.is_focused) {
                focused = merged_win;
            }
            if (merged_win.visible) {
                try visible.append(self.allocator, merged_win);
            }
        }

        const visible_windows = try visible.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(visible_windows);
        return .{
            .focused_window = focused,
            .visible_windows = visible_windows,
            .all_windows = try merged.toOwnedSlice(self.allocator),
        };
    }

    fn mergeWindow(
        self: *MergeEngine,
        win: niri_client.Window,
        viewport: ?niri_types.Rect,
        scale: f64,
        output_name: ?[]const u8,
        atspi_apps: ?[]atspi.AppInfo,
    ) !MergedWindow {
        // Calculate window geometry from layout
        const layout = win.layout;
        const ws = layout.window_size;
        const ts = layout.tile_size;
        const wo = layout.window_offset_in_tile;

        // CSD shadow calculation
        const shadow_left = wo[0];
        const shadow_top = wo[1];
        const shadow_right = ts[0] - @as(f64, @floatFromInt(ws[0])) - shadow_left;
        const shadow_bottom = ts[1] - @as(f64, @floatFromInt(ws[1])) - shadow_top;

        // Window logical rect (content area, excluding CSD shadows)
        const win_x: i32 = if (layout.tile_pos_in_workspace_view) |pos|
            @intFromFloat(pos[0] + wo[0])
        else
            0;

        const win_y: i32 = if (layout.tile_pos_in_workspace_view) |pos|
            @intFromFloat(pos[1] + wo[1])
        else
            0;

        const window_rect: niri_types.Rect = .{
            .x = win_x,
            .y = win_y,
            .width = @intCast(ws[0]),
            .height = @intCast(ws[1]),
        };

        const tile_rect: ?niri_types.Rect = if (layout.tile_pos_in_workspace_view) |pos| .{
            .x = @intFromFloat(pos[0]),
            .y = @intFromFloat(pos[1]),
            .width = @intFromFloat(ts[0]),
            .height = @intFromFloat(ts[1]),
        } else null;

        // Viewport clipping
        var is_visible = true;
        var visible_rect: ?niri_types.Rect = null;

        if (viewport) |vp| {
            if (tile_rect) |tr| {
                visible_rect = niri_types.Rect.intersect(tr, vp);
                if (visible_rect == null) {
                    is_visible = false;
                }
            } else {
                is_visible = true;
                visible_rect = window_rect;
            }
        }

        // AT-SPI2 enrichment: find matching app
        var regions: []RegionInfo = try self.allocator.alloc(RegionInfo, 0);
        errdefer freeOwnedRegions(self.allocator, regions);
        var atspi_available = false;
        var regions_truncated = false;
        var region_source: []const u8 = "bounding_box";
        // A missing compositor position keeps the existing (0,0) fallback,
        // but must not be presented to screenshot consumers as an exact bound.
        const bounds_estimated = layout.tile_pos_in_workspace_view == null;

        if (atspi_apps) |apps| {
            // Strategy 1: PID match
            var matched_app: ?atspi.AppInfo = null;

            if (win.pid) |pid| {
                if (pid > 0) {
                    for (apps) |app| {
                        if (app.pid == @as(u32, @intCast(pid))) {
                            matched_app = app;
                            break;
                        }
                    }
                }
            }

            // Prefer a PID root that actually has a matching accessible
            // window. Some Qt/plugin combinations register an empty root
            // before the real application root.
            if (win.pid) |pid| {
                if (pid > 0) for (apps) |app| {
                    if (app.pid != @as(u32, @intCast(pid))) continue;
                    if (atspi.findMatchingWindow(win, app.windows) != null) {
                        matched_app = app;
                        break;
                    }
                };
            }

            // Strategy 2: app_id / name fallback (for Flatpak PID namespace issues)
            if (matched_app == null) {
                if (win.app_id) |app_id| {
                    for (apps) |app| {
                        if (app.name) |name| {
                            if (std.ascii.indexOfIgnoreCase(app_id, name) != null or
                                std.ascii.indexOfIgnoreCase(name, app_id) != null)
                            {
                                matched_app = app;
                                break;
                            }
                        }
                    }
                }
            }

            if (matched_app) |app| {
                if (atspi.findMatchingWindow(win, app.windows)) |index| {
                    const atspi_win = app.windows[index];
                    atspi_available = atspi_win.queried;
                    regions_truncated = atspi_win.regions_truncated or !atspi_win.queried;
                    const atspi_regions = try mergeRegions(self.allocator, atspi_win.regions, window_rect, scale);
                    self.allocator.free(regions);
                    regions = atspi_regions;
                    if (regions.len > 0) region_source = "atspi2";
                }
            }
        }

        // Any application may expose no useful descendants. Keep the result
        // useful by returning the compositor window bounding box.
        if (regions.len == 0) {
            const fallback_rect = window_rect;
            const fallback_name = if (win.title) |title| try self.allocator.dupe(u8, title) else null;
            errdefer if (fallback_name) |name| self.allocator.free(name);
            const fallback = RegionInfo{
                .name = fallback_name,
                .role = "window",
                .bounds = .{
                    .logical = fallback_rect,
                    .physical = fallback_rect.scale(scale),
                    .scale = scale,
                },
            };
            const fallback_list = try self.allocator.alloc(RegionInfo, 1);
            fallback_list[0] = fallback;
            self.allocator.free(regions);
            regions = fallback_list;
            region_source = "bounding_box";
        }

        return .{
            .id = win.id,
            .title = win.title,
            .app_id = win.app_id,
            .pid = win.pid,
            .workspace_id = win.workspace_id,
            .is_focused = win.is_focused,
            .is_floating = win.is_floating,
            .is_urgent = win.is_urgent,
            .window_geometry = .{
                .logical = window_rect,
                .physical = window_rect.scale(scale),
                .scale = scale,
            },
            .tile_geometry = if (tile_rect) |tr| .{
                .logical = tr,
                .physical = tr.scale(scale),
                .scale = scale,
            } else null,
            .visible_geometry = if (visible_rect) |vr| .{
                .logical = vr,
                .physical = vr.scale(scale),
                .scale = scale,
            } else null,
            .visible = is_visible,
            .shadow_offset = .{
                .left = shadow_left,
                .top = shadow_top,
                .right = shadow_right,
                .bottom = shadow_bottom,
            },
            .atspi_available = atspi_available,
            .regions_truncated = regions_truncated,
            .region_source = region_source,
            .bounds_estimated = bounds_estimated,
            .regions = regions,
            .output_name = output_name,
        };
    }
};

fn matchesPid(window: niri_client.Window, pid: u32) bool {
    const window_pid = window.pid orelse return false;
    return window_pid > 0 and @as(u32, @intCast(window_pid)) == pid;
}

/// Clip window-relative bounds before scaling. Some providers use INT_MIN as
/// the location of hidden elements, which is not a valid screenshot region.
fn mergeRegions(allocator: Allocator, raw: []const atspi.Region, window: niri_types.Rect, scale: f64) ![]RegionInfo {
    const relative_window: niri_types.Rect = .{ .x = 0, .y = 0, .width = window.width, .height = window.height };
    var flat: std.ArrayList(RegionInfo) = .empty;
    defer flat.deinit(allocator);
    errdefer for (flat.items) |region| {
        if (region.name) |name| allocator.free(name);
    };

    for (raw) |region| {
        if (region.bounds.width <= 0 or region.bounds.height <= 0) continue;
        const rect: niri_types.Rect = .{
            .x = region.bounds.x,
            .y = region.bounds.y,
            .width = @intCast(region.bounds.width),
            .height = @intCast(region.bounds.height),
        };
        const clipped = niri_types.Rect.intersect(rect, relative_window) orelse continue;
        if (region.name == null and clipped.width == window.width and clipped.height == window.height and
            (std.mem.eql(u8, region.role, "panel") or std.mem.eql(u8, region.role, "grouping") or
                std.mem.eql(u8, region.role, "section"))) continue;
        const absolute: niri_types.Rect = .{
            .x = window.x + clipped.x,
            .y = window.y + clipped.y,
            .width = clipped.width,
            .height = clipped.height,
        };

        var duplicate: ?*RegionInfo = null;
        for (flat.items) |*existing| {
            if (std.meta.eql(existing.bounds.logical, absolute)) {
                duplicate = existing;
                break;
            }
        }
        if (duplicate) |existing| {
            if (existing.name == null and region.name != null) {
                existing.name = try allocator.dupe(u8, region.name.?);
            }
            continue;
        }

        const owned_name = if (region.name) |name| try allocator.dupe(u8, name) else null;
        errdefer if (owned_name) |name| allocator.free(name);
        try flat.append(allocator, .{
            .name = owned_name,
            .role = region.role,
            .bounds = .{ .logical = absolute, .physical = absolute.scale(scale), .scale = scale },
        });
    }

    return buildRegionTree(allocator, flat.items);
}

/// Build a geometry hierarchy; equal rectangles remain peers (normally deduplicated).
fn buildRegionTree(allocator: Allocator, regions: []const RegionInfo) ![]RegionInfo {
    if (regions.len == 0) return &.{};
    const parents = try allocator.alloc(?usize, regions.len);
    defer allocator.free(parents);
    for (regions, 0..) |child, i| {
        parents[i] = null;
        var smallest_area: u64 = std.math.maxInt(u64);
        for (regions, 0..) |candidate, j| {
            if (i == j or !strictlyContains(candidate.bounds.logical, child.bounds.logical)) continue;
            const area = @as(u64, candidate.bounds.logical.width) * candidate.bounds.logical.height;
            if (area < smallest_area) {
                smallest_area = area;
                parents[i] = j;
            }
        }
    }
    const offsets = try allocator.alloc(usize, regions.len + 2);
    defer allocator.free(offsets);
    @memset(offsets, 0);
    for (parents) |parent| offsets[(if (parent) |index| index + 1 else 0) + 1] += 1;
    for (1..offsets.len) |index| offsets[index] += offsets[index - 1];
    const positions = try allocator.dupe(usize, offsets[0 .. offsets.len - 1]);
    defer allocator.free(positions);
    const children = try allocator.alloc(usize, regions.len);
    defer allocator.free(children);
    for (parents, 0..) |parent, index| {
        const slot = if (parent) |value| value + 1 else 0;
        children[positions[slot]] = index;
        positions[slot] += 1;
    }
    return buildRegionChildren(allocator, regions, offsets, children, 0);
}

fn strictlyContains(parent: niri_types.Rect, child: niri_types.Rect) bool {
    const parent_right = @as(i64, parent.x) + parent.width;
    const parent_bottom = @as(i64, parent.y) + parent.height;
    const child_right = @as(i64, child.x) + child.width;
    const child_bottom = @as(i64, child.y) + child.height;
    return parent.x <= child.x and parent.y <= child.y and
        parent_right >= child_right and parent_bottom >= child_bottom and
        !(parent.x == child.x and parent.y == child.y and
            parent.width == child.width and parent.height == child.height);
}

fn buildRegionChildren(allocator: Allocator, regions: []const RegionInfo, offsets: []const usize, children: []const usize, parent_slot: usize) Allocator.Error![]RegionInfo {
    const indexes = children[offsets[parent_slot]..offsets[parent_slot + 1]];
    if (indexes.len == 0) return &.{};
    const nodes = try allocator.alloc(RegionInfo, indexes.len);
    var initialized: usize = 0;
    errdefer {
        for (nodes[0..initialized]) |node| freeRegionTree(allocator, node.children);
        allocator.free(nodes);
    }
    for (indexes, 0..) |index, position| {
        nodes[position] = regions[index];
        nodes[position].children = try buildRegionChildren(allocator, regions, offsets, children, index + 1);
        initialized += 1;
    }
    return nodes;
}

fn freeRegionTree(allocator: Allocator, nodes: []RegionInfo) void {
    for (nodes) |node| freeRegionTree(allocator, node.children);
    allocator.free(nodes);
}

fn freeOwnedRegions(allocator: Allocator, nodes: []RegionInfo) void {
    for (nodes) |node| node.deinit(allocator);
    allocator.free(nodes);
}

test "region merging clips invalid coordinates before scaling" {
    const raw = [_]atspi.Region{
        .{ .name = null, .role = "panel", .bounds = .{ .x = -2_000_000_000, .y = -2_000_000_000, .width = 10, .height = 10 } },
        .{ .name = "button", .role = "button", .bounds = .{ .x = -5, .y = 10, .width = 20, .height = 20 } },
    };
    const window: niri_types.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const regions = try mergeRegions(std.testing.allocator, &raw, window, 1.25);
    defer freeOwnedRegions(std.testing.allocator, regions);
    try std.testing.expectEqual(@as(usize, 1), regions.len);
    try std.testing.expectEqual(@as(i32, 0), regions[0].bounds.logical.x);
    try std.testing.expectEqual(@as(i32, 10), regions[0].bounds.logical.y);
    try std.testing.expectEqual(@as(u32, 15), regions[0].bounds.logical.width);
}

test "region tree cleans up at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

fn allocationScenario(allocator: Allocator) !void {
    const raw = [_]atspi.Region{
        .{ .name = "parent", .role = "panel", .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 } },
        .{ .name = "child", .role = "button", .bounds = .{ .x = 5, .y = 5, .width = 20, .height = 20 } },
        .{ .name = "sibling", .role = "entry", .bounds = .{ .x = 50, .y = 5, .width = 20, .height = 20 } },
    };
    const regions = try mergeRegions(allocator, &raw, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, 1.25);
    defer freeOwnedRegions(allocator, regions);
    try std.testing.expectEqual(@as(usize, 1), regions.len);
    try std.testing.expectEqual(@as(usize, 2), regions[0].children.len);
}

test "region hierarchy chooses smallest containing rectangle regardless of input order" {
    const rects = [_]niri_types.Rect{
        .{ .x = 10, .y = 10, .width = 10, .height = 10 },
        .{ .x = 0, .y = 0, .width = 100, .height = 100 },
        .{ .x = 5, .y = 5, .width = 50, .height = 50 },
        .{ .x = 200, .y = 0, .width = 20, .height = 20 },
        .{ .x = 90, .y = 90, .width = 20, .height = 20 },
    };
    var regions: [rects.len]RegionInfo = undefined;
    for (rects, 0..) |rect, i| regions[i] = .{
        .name = null,
        .role = "panel",
        .bounds = .{ .logical = rect, .physical = rect.scale(1.25), .scale = 1.25 },
    };
    const tree = try buildRegionTree(std.testing.allocator, &regions);
    defer freeRegionTree(std.testing.allocator, tree);
    try std.testing.expectEqual(@as(usize, 3), tree.len);
    try std.testing.expectEqual(@as(usize, 1), tree[0].children.len);
    try std.testing.expectEqual(@as(usize, 1), tree[0].children[0].children.len);
    try std.testing.expectEqual(@as(i32, 10), tree[0].children[0].children[0].bounds.logical.x);
    try std.testing.expect(!strictlyContains(rects[1], rects[1]));
    try std.testing.expect(strictlyContains(rects[1], .{ .x = 0, .y = 0, .width = 100, .height = 50 }));
}
