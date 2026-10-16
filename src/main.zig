const std = @import("std");
const niri = @import("niri/client.zig");
const atspi = @import("atspi/bindings.zig");
const merge = @import("merge.zig");
const Output = @import("output.zig").Output;

const Command = enum { smart, windows, focused, outputs, workspaces, tree, regions, help, version };
const Options = struct {
    command: Command = .help,
    window_id: ?u64 = null,
    pid: ?u32 = null,
    engine: merge.Options = .{},
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var stdout_buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.Writer.init(.stdout(), init.io, &stdout_buffer);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.Writer.init(.stderr(), init.io, &stderr_buffer);
    const args = try init.minimal.args.toSlice(allocator);
    const options = parseArgs(args) catch |err| {
        try stderr.interface.print("Error: {s}; see zebry --help\n", .{@errorName(err)});
        try stderr.interface.flush();
        std.process.exit(1);
    };
    run(allocator, &stdout.interface, options) catch |err| {
        try stderr.interface.print("Error: {s}\n", .{@errorName(err)});
        try stderr.interface.flush();
        std.process.exit(1);
    };
    try stdout.interface.flush();
}

fn parseArgs(args: []const [:0]const u8) !Options {
    var options = Options{};
    if (args.len < 2) return options;
    options.command = if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))
        .help
    else if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v"))
        .version
    else
        std.meta.stringToEnum(Command, args[1]) orelse return error.UnknownCommand;
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const flag = args[index];
        if (std.mem.eql(u8, flag, "--no-atspi")) {
            options.engine.atspi_enabled = false;
            continue;
        }
        if (std.mem.eql(u8, flag, "--include-web")) {
            options.engine.include_web = true;
            continue;
        }
        if (index + 1 >= args.len) return error.MissingOptionValue;
        index += 1;
        if (std.mem.eql(u8, flag, "--window-id")) {
            options.window_id = try std.fmt.parseInt(u64, args[index], 10);
        } else if (std.mem.eql(u8, flag, "--pid")) {
            options.pid = try std.fmt.parseInt(u32, args[index], 10);
        } else if (std.mem.eql(u8, flag, "--depth")) {
            options.engine.query.max_depth = @min(32, try std.fmt.parseInt(u32, args[index], 10));
        } else if (std.mem.eql(u8, flag, "--budget-ms")) {
            options.engine.query.budget_ms = @min(1000, try std.fmt.parseInt(u32, args[index], 10));
        } else {
            return error.UnknownOption;
        }
    }
    return options;
}

fn run(allocator: std.mem.Allocator, writer: *std.Io.Writer, options: Options) !void {
    switch (options.command) {
        .help => try printHelp(writer),
        .version => try writer.writeAll("zebry 0.1.0\n"),
        .windows, .outputs, .workspaces => {
            const client = try niri.Client.init(allocator);
            switch (options.command) {
                .windows => try Output.writeNiriWindows(writer, try client.getWindows()),
                .outputs => try std.json.Stringify.value(try client.getOutputs(), .{ .whitespace = .indent_2 }, writer),
                .workspaces => try std.json.Stringify.value(try client.getWorkspaces(), .{ .whitespace = .indent_2 }, writer),
                else => unreachable,
            }
            if (options.command != .windows) try writer.writeByte('\n');
        },
        .tree => try runTree(allocator, writer, options),
        .smart, .focused, .regions => {
            var engine = try merge.MergeEngine.initWithOptions(allocator, options.engine);
            defer engine.deinit();
            switch (options.command) {
                .smart => try Output.writeSmartOutput(writer, try engine.buildSmartOutput()),
                .focused => try Output.writeSingleWindow(writer, try engine.buildWindowOutput(options.window_id)),
                .regions => {
                    if (options.pid != null and options.window_id == null) {
                        const windows = try engine.buildPidOutput(options.pid.?);
                        try Output.writeWindowRegions(writer, windows);
                    } else if (try engine.buildWindowOutput(options.window_id)) |window| {
                        try Output.writeRegions(writer, window.regions);
                    } else {
                        try writer.writeAll("[]\n");
                    }
                },
                else => unreachable,
            }
        },
    }
}

fn runTree(allocator: std.mem.Allocator, writer: *std.Io.Writer, options: Options) !void {
    if (!options.engine.atspi_enabled) {
        try writer.writeAll("null\n");
        return;
    }
    var pid = options.pid;
    if (pid == null) {
        const client = try niri.Client.init(allocator);
        var window: ?niri.Window = null;
        if (options.window_id) |id| {
            for (try client.getWindows()) |candidate| {
                if (candidate.id == id) {
                    window = candidate;
                    break;
                }
            }
            if (window == null) return error.WindowNotFound;
        } else {
            window = try client.getFocusedWindow();
        }
        if (window) |value| {
            if (value.pid) |process_id| if (process_id > 0) {
                pid = @intCast(process_id);
            };
        }
    }
    const target_pid = pid orelse return error.WindowNotFound;
    var bindings = atspi.Bindings.init(allocator) catch {
        try writer.writeAll("null\n");
        return;
    };
    defer bindings.deinit();
    if (try bindings.findAppByPid(target_pid, options.engine.query)) |app| {
        defer app.deinit(allocator);
        try writer.writeAll("{\"app\": ");
        try std.json.Stringify.value(app.name, .{}, writer);
        try writer.print(", \"pid\": {d}, \"windows\": [", .{app.pid});
        for (app.windows, 0..) |window, index| {
            if (index > 0) try writer.writeByte(',');
            try std.json.Stringify.value(.{
                .name = window.name,
                .role = window.role,
                .bounds = window.bounds,
                .regions_count = window.regions.len,
            }, .{}, writer);
        }
        try writer.writeAll("]}\n");
    } else {
        try writer.writeAll("null\n");
    }
}

fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\zebry — Niri screenshot geometry CLI
        \\
        \\USAGE:
        \\  zebry <command> [options]
        \\
        \\COMMANDS:
        \\  smart         Windows with optional native UI regions
        \\  focused       Focused or --window-id window
        \\  regions       Hierarchical native UI regions
        \\  windows       Window metadata from Niri
        \\  outputs       Display outputs
        \\  workspaces    Workspaces
        \\  tree          AT-SPI application/window summary
        \\  help          Print this help
        \\  version       Print version
        \\
        \\OPTIONS:
        \\  --window-id <ID>  Select a Niri window
        \\  --pid <PID>       Select an application for regions/tree
        \\  --depth <N>       Native UI depth (default 16, maximum 32)
        \\  --budget-ms <N>   AT-SPI traversal budget (default 50, max 1000)
        \\  --include-web     Traverse browser document web nodes (higher cost)
        \\  --no-atspi        Niri geometry only; skip accessibility startup
        \\
        \\ENVIRONMENT:
        \\  NIRI_SOCKET       Niri IPC socket
        \\
    );
}
