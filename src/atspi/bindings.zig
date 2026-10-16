const std = @import("std");
const api = @import("api.zig");
const enabled = @import("build_options").atspi;
const niri = @import("../niri/types.zig");
const Allocator = std.mem.Allocator;

pub const AccessibleRect = struct { x: i32, y: i32, width: i32, height: i32 };

pub const Region = struct {
    name: ?[]const u8,
    // Static role names avoid a string allocation and D-Bus role-name query
    // for every accessible node.
    role: []const u8,
    bounds: AccessibleRect,

    pub fn deinit(self: Region, allocator: Allocator) void {
        if (self.name) |name| allocator.free(name);
    }
};

pub const WindowInfo = struct {
    name: ?[]const u8,
    role: []const u8,
    bounds: ?AccessibleRect,
    regions: []Region,
    queried: bool = false,
    regions_truncated: bool = false,

    pub fn deinit(self: WindowInfo, allocator: Allocator) void {
        if (self.name) |name| allocator.free(name);
        for (self.regions) |region| region.deinit(allocator);
        allocator.free(self.regions);
    }
};

pub const AppInfo = struct {
    name: ?[]const u8,
    pid: u32,
    windows: []WindowInfo,

    pub fn deinit(self: AppInfo, allocator: Allocator) void {
        if (self.name) |name| allocator.free(name);
        for (self.windows) |window| window.deinit(allocator);
        allocator.free(self.windows);
    }
};

pub const QueryResult = struct {
    apps: []AppInfo,
    exhausted: bool = false,
    incomplete: bool = false,
};

pub const QueryOptions = struct {
    max_depth: u32 = 16,
    max_nodes: usize = 1024,
    max_regions: usize = 128,
    budget_ms: u32 = 50,
    include_web: bool = false,
};

const Budget = struct {
    deadline: i64,
    remaining_nodes: usize,
    truncated: bool = false,
    incomplete: bool = false,

    fn init(options: QueryOptions) Budget {
        return .{ .deadline = millis() + options.budget_ms, .remaining_nodes = options.max_nodes };
    }

    fn exhausted(self: Budget) bool {
        return self.remaining_nodes == 0 or millis() >= self.deadline;
    }

    fn prepareCall(self: *Budget, maximum_ms: u32) bool {
        const remaining = self.deadline - millis();
        if (remaining <= 0 or self.remaining_nodes == 0) {
            self.truncated = true;
            return false;
        }
        // libatspi's timeout is process-wide. This CLI queries synchronously,
        // so no call should wait longer than the remaining snapshot budget.
        if (enabled) api.atspi_set_timeout(callTimeout(remaining, maximum_ms), -1);
        return true;
    }

    fn failed(self: *Budget) void {
        self.truncated = true;
        self.incomplete = true;
    }
};

pub const Bindings = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) error{InitFailed}!Bindings {
        if (!enabled) return error.InitFailed;
        // A short-lived snapshot does not consume Cache.GetItems. Some
        // providers (including Niri) expose accessibles without a cache
        // object; bulk cache loading can also delay unrelated applications.
        // This setting is local to this process. Respect an explicit user
        // ATSPI_NO_CACHE=0 override rather than installing a log suppressor.
        if (api.g_setenv("ATSPI_NO_CACHE", "1", 0) == 0) return error.InitFailed;
        api.atspi_set_timeout(50, -1);
        if (api.atspi_init() != 0) return error.InitFailed;
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *Bindings) void {
        if (enabled) _ = api.atspi_exit();
    }

    /// Only load applications represented in the selected compositor windows.
    /// Top-level metadata is read first; descendant queries are restricted to
    /// the matching accessible windows, even when an application shares a PID.
    pub fn getApplicationsForWindows(self: *const Bindings, targets: []const niri.Window, options: QueryOptions) !QueryResult {
        if (!enabled) return .{ .apps = try self.allocator.alloc(AppInfo, 0) };
        var apps: std.ArrayList(AppInfo) = .empty;
        errdefer {
            for (apps.items) |app| app.deinit(self.allocator);
            apps.deinit(self.allocator);
        }
        if (targets.len == 0) return .{ .apps = try apps.toOwnedSlice(self.allocator) };
        var budget = Budget.init(options);
        const desktop = api.atspi_get_desktop(0) orelse return .{ .apps = try apps.toOwnedSlice(self.allocator) };
        defer unref(desktop);
        const count = readChildCount(desktop, &budget) orelse return .{
            .apps = try apps.toOwnedSlice(self.allocator),
            .exhausted = budget.exhausted(),
            .incomplete = true,
        };
        for (0..count) |index| {
            if (budget.exhausted()) break;
            budget.remaining_nodes -= 1;
            const app = readChild(desktop, index, &budget) orelse continue;
            defer unref(app);
            const pid = readPid(app, &budget) orelse continue;
            const pid_match = matchesPid(targets, pid);
            const name = if (pid_match) null else try self.copyName(app, &budget);
            defer if (name) |value| self.allocator.free(value);
            if (!pid_match and !matchesApp(targets, pid, name)) continue;
            const info = try self.loadApp(app, pid, name, targets, options, &budget);
            errdefer info.deinit(self.allocator);
            try apps.append(self.allocator, info);
        }
        return .{
            .apps = try apps.toOwnedSlice(self.allocator),
            .exhausted = budget.exhausted(),
            .incomplete = budget.incomplete,
        };
    }

    /// Diagnostic command: query one PID and report its window summaries.
    pub fn findAppByPid(self: *const Bindings, target_pid: u32, options: QueryOptions) !?AppInfo {
        if (!enabled) return null;
        var budget = Budget.init(options);
        const desktop = api.atspi_get_desktop(0) orelse return null;
        defer unref(desktop);
        const count = readChildCount(desktop, &budget) orelse return error.QueryFailed;
        for (0..count) |index| {
            if (budget.exhausted()) break;
            budget.remaining_nodes -= 1;
            const app = readChild(desktop, index, &budget) orelse continue;
            defer unref(app);
            if (readPid(app, &budget) != target_pid) continue;
            const name = try self.copyName(app, &budget);
            defer if (name) |value| self.allocator.free(value);
            return try self.loadApp(app, target_pid, name, null, options, &budget);
        }
        return null;
    }

    fn loadApp(self: *const Bindings, app: *api.AtspiAccessible, pid: u32, name: ?[]const u8, targets: ?[]const niri.Window, options: QueryOptions, budget: *Budget) !AppInfo {
        const owned_name = if (name) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_name) |value| self.allocator.free(value);
        var windows: std.ArrayList(WindowInfo) = .empty;
        errdefer {
            for (windows.items) |window| window.deinit(self.allocator);
            windows.deinit(self.allocator);
        }
        var accessibles: std.ArrayList(*api.AtspiAccessible) = .empty;
        defer {
            for (accessibles.items) |accessible| unref(accessible);
            accessibles.deinit(self.allocator);
        }
        const count = readChildCount(app, budget) orelse 0;
        for (0..count) |index| {
            if (budget.exhausted()) break;
            budget.remaining_nodes -= 1;
            const child = readChild(app, index, budget) orelse continue;
            const role = readRole(child, budget) orelse {
                unref(child);
                continue;
            };
            if (!isWindowRole(role)) {
                unref(child);
                continue;
            }
            accessibles.append(self.allocator, child) catch |err| {
                unref(child);
                return err;
            };
            const win_name = try self.copyName(child, budget);
            errdefer if (win_name) |value| self.allocator.free(value);
            try windows.append(self.allocator, .{
                .name = win_name,
                .role = roleName(role) orelse "window",
                .bounds = null,
                .regions = &.{},
            });
        }
        // Geometry is needed only for diagnostics or when titles cannot
        // identify a window. Avoid a D-Bus extents query per sibling window.
        var needs_geometry = targets == null;
        if (targets) |selected| {
            for (selected) |target| {
                if (!matchesApp(&.{target}, pid, name)) continue;
                var title_matched = false;
                if (target.title) |title| {
                    for (windows.items) |window| {
                        if (window.name) |value| {
                            if (std.mem.eql(u8, title, value)) title_matched = true;
                        }
                    }
                }
                if (!title_matched and windows.items.len > 1) needs_geometry = true;
            }
        }
        if (needs_geometry) {
            for (windows.items, 0..) |*window, index| {
                if (budget.exhausted()) break;
                window.bounds = getBounds(accessibles.items[index], budget);
            }
        }
        // The same matching function is used by the merge layer. Selection
        // happens before recursion, so sibling windows never need full trees.
        if (targets) |selected| {
            for (selected) |target| {
                if (!matchesApp(&.{target}, pid, name)) continue;
                if (findMatchingWindow(target, windows.items)) |index| {
                    if (windows.items[index].queried) continue;
                    if (budget.exhausted()) break;
                    budget.truncated = false;
                    const traverse_documents = options.include_web or shouldTraverseDocuments(target.app_id);
                    windows.items[index].regions = try self.readRegions(accessibles.items[index], options, budget, traverse_documents);
                    windows.items[index].regions_truncated = budget.truncated;
                    windows.items[index].queried = true;
                }
            }
        } else {
            for (windows.items, 0..) |*window, index| {
                if (budget.exhausted()) break;
                budget.truncated = false;
                window.regions = try self.readRegions(accessibles.items[index], options, budget, options.include_web or shouldTraverseDocuments(name));
                window.regions_truncated = budget.truncated;
                window.queried = true;
            }
        }
        return .{ .name = owned_name, .pid = pid, .windows = try windows.toOwnedSlice(self.allocator) };
    }

    fn readRegions(self: *const Bindings, window: *api.AtspiAccessible, options: QueryOptions, budget: *Budget, traverse_documents: bool) ![]Region {
        var regions: std.ArrayList(Region) = .empty;
        errdefer {
            for (regions.items) |region| region.deinit(self.allocator);
            regions.deinit(self.allocator);
        }
        try self.collectRegions(window, &regions, options, budget, 0, traverse_documents);
        return regions.toOwnedSlice(self.allocator);
    }

    fn collectRegions(self: *const Bindings, node: *api.AtspiAccessible, regions: *std.ArrayList(Region), options: QueryOptions, budget: *Budget, depth: u32, traverse_documents: bool) Allocator.Error!void {
        if (depth >= options.max_depth or budget.exhausted() or regions.items.len >= options.max_regions) {
            budget.truncated = true;
            return;
        }
        const count = readChildCount(node, budget) orelse return;
        for (0..count) |index| {
            if (budget.exhausted() or regions.items.len >= options.max_regions) {
                budget.truncated = true;
                break;
            }
            budget.remaining_nodes -= 1;
            const child = readChild(node, index, budget) orelse continue;
            defer unref(child);
            const role = readRole(child, budget) orelse continue;
            if (roleName(role)) |name| {
                if (getBounds(child, budget)) |rect| {
                    // Providers often use INT_MIN for hidden nodes. Reject
                    // these before any string allocations or pixel scaling.
                    if (rect.width > 0 and rect.height > 0 and
                        @as(i64, rect.x) + rect.width > 0 and @as(i64, rect.y) + rect.height > 0)
                    {
                        if (budget.exhausted()) {
                            budget.truncated = true;
                            break;
                        }
                        const owned_name = try self.copyName(child, budget);
                        errdefer if (owned_name) |value| self.allocator.free(value);
                        try regions.append(self.allocator, .{ .name = owned_name, .role = name, .bounds = rect });
                    }
                }
            }
            // Electron/Tauri use document nodes for the entire desktop UI.
            // Skip descendants only for standalone browser applications.
            if (descendInto(role, traverse_documents)) {
                try self.collectRegions(child, regions, options, budget, depth + 1, traverse_documents);
            }
        }
    }

    fn copyName(self: *const Bindings, accessible: *api.AtspiAccessible, budget: *Budget) !?[]const u8 {
        if (!budget.prepareCall(50)) return null;
        var query_error: ?*api.GError = null;
        const ptr = api.atspi_accessible_get_name(accessible, &query_error);
        defer if (ptr != null) api.g_free(@ptrCast(ptr));
        if (query_error) |err| {
            api.g_error_free(err);
            budget.failed();
            return null;
        }
        if (ptr == null) {
            budget.failed();
            return null;
        }
        const text = std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
        if (text.len == 0) return null;
        return try self.allocator.dupe(u8, text);
    }
};

fn millis() i64 {
    var time: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &time) != 0) return 0;
    return @as(i64, @intCast(time.sec)) * 1000 + @divTrunc(time.nsec, 1_000_000);
}

fn unref(object: anytype) void {
    api.g_object_unref(@ptrCast(object));
}

fn callTimeout(remaining_ms: i64, maximum_ms: u32) c_int {
    return @intCast(@max(1, @min(remaining_ms, maximum_ms)));
}

fn readChildCount(accessible: *api.AtspiAccessible, budget: *Budget) ?usize {
    return readChildCountWith(accessible, budget, api.atspi_accessible_get_child_count);
}

fn readChildCountWith(accessible: *api.AtspiAccessible, budget: *Budget, comptime query: anytype) ?usize {
    for (0..2) |attempt| {
        if (!budget.prepareCall(if (attempt == 0) 50 else 100)) {
            budget.failed();
            return null;
        }
        var query_error: ?*api.GError = null;
        const count = query(accessible, &query_error);
        if (query_error) |err| {
            api.g_error_free(err);
        } else if (count >= 0) {
            return @intCast(count);
        }
        // _atspi_dbus_get_property can return -1 without setting GError.
        // Retry once within the remaining budget; never turn failure into 0.
    }
    budget.failed();
    return null;
}

fn readChild(accessible: *api.AtspiAccessible, index: usize, budget: *Budget) ?*api.AtspiAccessible {
    if (!budget.prepareCall(50)) return null;
    var query_error: ?*api.GError = null;
    const child = api.atspi_accessible_get_child_at_index(accessible, @intCast(index), &query_error);
    if (query_error) |err| {
        api.g_error_free(err);
        if (child) |value| unref(value);
        budget.failed();
        return null;
    }
    if (child == null) budget.failed();
    return child;
}

fn readRole(accessible: *api.AtspiAccessible, budget: *Budget) ?api.AtspiRole {
    if (!budget.prepareCall(50)) return null;
    var query_error: ?*api.GError = null;
    const role = api.atspi_accessible_get_role(accessible, &query_error);
    if (query_error) |err| {
        api.g_error_free(err);
        budget.failed();
        return null;
    }
    if (role == 0) {
        budget.failed();
        return null;
    }
    return role;
}

fn readPid(accessible: *api.AtspiAccessible, budget: *Budget) ?u32 {
    if (!budget.prepareCall(50)) return null;
    var query_error: ?*api.GError = null;
    const pid = api.atspi_accessible_get_process_id(accessible, &query_error);
    if (query_error) |err| {
        api.g_error_free(err);
        budget.failed();
        return null;
    }
    if (pid == 0 or pid == std.math.maxInt(u32)) {
        budget.failed();
        return null;
    }
    return pid;
}

fn getBounds(accessible: *api.AtspiAccessible, budget: *Budget) ?AccessibleRect {
    if (!budget.prepareCall(50)) return null;
    if (api.atspi_accessible_is_component(accessible) == 0) return null;
    if (!budget.prepareCall(50)) return null;
    const component = api.atspi_accessible_get_component_iface(accessible) orelse return null;
    defer unref(component);
    if (!budget.prepareCall(50)) return null;
    var query_error: ?*api.GError = null;
    const rect = api.atspi_component_get_extents(component, api.coord_type_window, &query_error);
    defer if (rect) |value| api.g_free(@ptrCast(value));
    if (query_error) |err| {
        api.g_error_free(err);
        budget.failed();
        return null;
    }
    const value = rect orelse {
        budget.failed();
        return null;
    };
    return .{ .x = value.x, .y = value.y, .width = value.width, .height = value.height };
}

fn shouldTraverseDocuments(app_id: ?[]const u8) bool {
    const id = app_id orelse return true;
    // Recognize known browser identifiers, not arbitrary substrings such as
    // "edge" in a desktop app's name. Unknown apps keep their desktop UI.
    const browser_ids = [_][]const u8{
        "google-chrome",       "google-chrome-stable",   "google-chrome-beta",    "google-chrome-unstable",
        "com.google.Chrome",   "com.google.Chrome.beta", "com.google.Chrome.dev", "chromium",
        "chromium-browser",    "org.chromium.Chromium",  "brave",                 "brave-browser",
        "com.brave.Browser",   "com.brave.Browser.beta", "firefox",               "firefox-esr",
        "org.mozilla.firefox", "org.mozilla.Firefox",    "microsoft-edge",        "microsoft-edge-beta",
        "microsoft-edge-dev",  "msedge",                 "com.microsoft.Edge",    "vivaldi",
        "vivaldi-stable",      "com.vivaldi.Vivaldi",    "opera",                 "com.opera.Opera",
    };
    for (browser_ids) |browser| if (std.ascii.eqlIgnoreCase(id, browser)) return false;
    // Chromium PWAs use app ids such as chrome-<app hash>-Default.
    if (std.ascii.startsWithIgnoreCase(id, "chrome-") or std.ascii.startsWithIgnoreCase(id, "chromium-")) return false;
    return true;
}

fn descendInto(role: api.AtspiRole, traverse_documents: bool) bool {
    return traverse_documents or !isDocumentRole(role);
}

fn matchesPid(targets: []const niri.Window, pid: u32) bool {
    for (targets) |target| {
        if (target.pid) |target_pid| {
            if (target_pid > 0 and @as(u32, @intCast(target_pid)) == pid) return true;
        }
    }
    return false;
}

fn matchesApp(targets: []const niri.Window, pid: u32, name: ?[]const u8) bool {
    for (targets) |target| {
        if (target.pid) |target_pid| {
            if (target_pid > 0 and @as(u32, @intCast(target_pid)) == pid) return true;
        }
        if (target.app_id) |app_id| {
            if (name) |value| {
                if (value.len != 0 and (std.ascii.indexOfIgnoreCase(app_id, value) != null or
                    std.ascii.indexOfIgnoreCase(value, app_id) != null)) return true;
            }
        }
    }
    return false;
}

pub fn findMatchingWindow(window: niri.Window, candidates: []const WindowInfo) ?usize {
    if (candidates.len == 0) return null;
    if (candidates.len == 1) return 0;
    if (window.title) |title| {
        for (candidates, 0..) |candidate, index| {
            if (candidate.name) |name| if (std.mem.eql(u8, title, name)) return index;
        }
        for (candidates, 0..) |candidate, index| {
            if (candidate.name) |name| {
                if (std.ascii.indexOfIgnoreCase(title, name) != null or
                    std.ascii.indexOfIgnoreCase(name, title) != null) return index;
            }
        }
    }
    for (candidates, 0..) |candidate, index| {
        if (candidate.bounds) |bounds| {
            if (bounds.width == window.layout.window_size[0] and bounds.height == window.layout.window_size[1]) return index;
        }
    }
    return 0;
}

test "desktop WebView documents are traversed while browser pages stay excluded" {
    for ([_]?[]const u8{ "clash-verge", "com.microsoft.VSCode", "code", "discord", "wechat", "com.example.Knowledge", null }) |id| {
        try std.testing.expect(descendInto(api.ATSPI_ROLE_DOCUMENT_WEB, shouldTraverseDocuments(id)));
        try std.testing.expect(descendInto(api.ATSPI_ROLE_HTML_CONTAINER, shouldTraverseDocuments(id)));
    }
    for ([_][]const u8{ "google-chrome", "org.chromium.Chromium", "com.brave.Browser", "firefox", "com.microsoft.Edge", "chrome-abcd-Default" }) |id| {
        try std.testing.expect(!descendInto(api.ATSPI_ROLE_DOCUMENT_WEB, shouldTraverseDocuments(id)));
        try std.testing.expect(descendInto(api.ATSPI_ROLE_PANEL, shouldTraverseDocuments(id)));
    }
}

test "window selection uses titles before geometry for a shared PID" {
    const window: niri.Window = .{
        .id = 3,
        .title = "target",
        .is_focused = false,
        .is_floating = false,
        .is_urgent = false,
        .layout = .{ .tile_size = .{ 100, 100 }, .window_size = .{ 100, 100 }, .window_offset_in_tile = .{ 0, 0 } },
    };
    const candidates = [_]WindowInfo{
        .{ .name = "sibling", .role = "frame", .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 }, .regions = &.{} },
        .{ .name = "target", .role = "frame", .bounds = null, .regions = &.{} },
    };
    try std.testing.expectEqual(@as(?usize, 1), findMatchingWindow(window, &candidates));
    try std.testing.expect(isDocumentRole(api.ATSPI_ROLE_DOCUMENT_WEB));
    try std.testing.expect(isDocumentRole(api.ATSPI_ROLE_HTML_CONTAINER));
    try std.testing.expect(!isDocumentRole(api.ATSPI_ROLE_PANEL));
}

fn isWindowRole(role: api.AtspiRole) bool {
    return role == api.ATSPI_ROLE_FRAME or role == api.ATSPI_ROLE_WINDOW or
        role == api.ATSPI_ROLE_DIALOG or role == api.ATSPI_ROLE_ALERT;
}

fn isDocumentRole(role: api.AtspiRole) bool {
    return role == api.ATSPI_ROLE_DOCUMENT_WEB or role == api.ATSPI_ROLE_DOCUMENT_FRAME or role == api.ATSPI_ROLE_HTML_CONTAINER;
}

fn roleName(role: api.AtspiRole) ?[]const u8 {
    return switch (role) {
        api.ATSPI_ROLE_FRAME => "frame",
        api.ATSPI_ROLE_WINDOW => "window",
        api.ATSPI_ROLE_DIALOG => "dialog",
        api.ATSPI_ROLE_ALERT => "alert",
        api.ATSPI_ROLE_TOOL_BAR => "tool bar",
        api.ATSPI_ROLE_MENU_BAR => "menu bar",
        api.ATSPI_ROLE_PAGE_TAB_LIST => "page tab list",
        api.ATSPI_ROLE_PAGE_TAB => "page tab",
        api.ATSPI_ROLE_PANEL => "panel",
        api.ATSPI_ROLE_STATUS_BAR => "status bar",
        api.ATSPI_ROLE_SCROLL_PANE => "scroll pane",
        api.ATSPI_ROLE_SCROLL_BAR => "scroll bar",
        api.ATSPI_ROLE_SPLIT_PANE => "split pane",
        api.ATSPI_ROLE_HEADER => "header",
        api.ATSPI_ROLE_FOOTER => "footer",
        api.ATSPI_ROLE_DOCUMENT_FRAME => "document frame",
        api.ATSPI_ROLE_DOCUMENT_WEB => "document web",
        api.ATSPI_ROLE_HTML_CONTAINER => "document web",
        api.ATSPI_ROLE_DOCUMENT_TEXT => "document text",
        api.ATSPI_ROLE_DOCUMENT_EMAIL => "document email",
        api.ATSPI_ROLE_PARAGRAPH => "paragraph",
        api.ATSPI_ROLE_HEADING => "heading",
        api.ATSPI_ROLE_PAGE => "page",
        api.ATSPI_ROLE_LINK => "link",
        api.ATSPI_ROLE_TABLE_ROW => "table row",
        api.ATSPI_ROLE_LIST_BOX => "list box",
        api.ATSPI_ROLE_ARTICLE => "article",
        api.ATSPI_ROLE_LANDMARK => "landmark",
        api.ATSPI_ROLE_STATIC => "static",
        api.ATSPI_ROLE_SEPARATOR => "separator",
        api.ATSPI_ROLE_CANVAS => "canvas",
        api.ATSPI_ROLE_TERMINAL => "terminal",
        api.ATSPI_ROLE_ENTRY => "entry",
        api.ATSPI_ROLE_TEXT => "text",
        api.ATSPI_ROLE_BUTTON => "button",
        api.ATSPI_ROLE_TOGGLE_BUTTON => "toggle button",
        api.ATSPI_ROLE_CHECK_BOX => "check box",
        api.ATSPI_ROLE_RADIO_BUTTON => "radio button",
        api.ATSPI_ROLE_COMBO_BOX => "combo box",
        api.ATSPI_ROLE_LIST => "list",
        api.ATSPI_ROLE_LIST_ITEM => "list item",
        api.ATSPI_ROLE_MENU => "menu",
        api.ATSPI_ROLE_MENU_ITEM => "menu item",
        api.ATSPI_ROLE_TABLE => "table",
        api.ATSPI_ROLE_TABLE_CELL => "table cell",
        api.ATSPI_ROLE_TREE => "tree",
        api.ATSPI_ROLE_TREE_ITEM => "tree item",
        api.ATSPI_ROLE_SLIDER => "slider",
        api.ATSPI_ROLE_SPIN_BUTTON => "spin button",
        api.ATSPI_ROLE_PROGRESS_BAR => "progress bar",
        api.ATSPI_ROLE_FORM => "form",
        api.ATSPI_ROLE_SECTION => "section",
        api.ATSPI_ROLE_GROUPING => "grouping",
        api.ATSPI_ROLE_IMAGE => "image",
        api.ATSPI_ROLE_VIEWPORT => "viewport",
        api.ATSPI_ROLE_OPTION_PANE => "option pane",
        else => null,
    };
}
