const std = @import("std");
const types = @import("types.zig");
const c = std.c;

pub const Window = types.Window;
pub const Output = types.Output;
pub const Workspace = types.Workspace;
pub const Rect = types.Rect;
pub const OutputGeometry = struct {
    name: []const u8,
    logical: ?types.LogicalOutput = null,
};

/// Snapshot data is allocated into the caller's arena. JSON is decoded straight
/// into the result types, without a dynamic Value tree or second string copies.
pub const Client = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,

    pub fn init(allocator: std.mem.Allocator) error{SocketNotFound}!Client {
        const value = c.getenv("NIRI_SOCKET") orelse return error.SocketNotFound;
        return .{ .allocator = allocator, .socket_path = std.mem.span(value) };
    }

    pub fn getWindows(self: *const Client) ![]Window {
        return (try self.request(struct { Windows: []Window }, "Windows")).Windows;
    }

    pub fn getFocusedWindow(self: *const Client) !?Window {
        return (try self.request(struct { FocusedWindow: ?Window }, "FocusedWindow")).FocusedWindow;
    }

    pub fn getOutputs(self: *const Client) ![]Output {
        return self.getOutputMap(Output);
    }

    /// The merge path only needs logical geometry. Skip mode lists, hardware
    /// strings and other output metadata while parsing the same IPC response.
    pub fn getOutputGeometries(self: *const Client) ![]OutputGeometry {
        return self.getOutputMap(OutputGeometry);
    }

    fn getOutputMap(self: *const Client, comptime T: type) ![]T {
        const result = try self.request(struct { Outputs: std.json.ArrayHashMap(T) }, "Outputs");
        return result.Outputs.map.values();
    }

    pub fn getWorkspaces(self: *const Client) ![]Workspace {
        return (try self.request(struct { Workspaces: []Workspace }, "Workspaces")).Workspaces;
    }

    fn request(self: *const Client, comptime T: type, comptime name: []const u8) !T {
        const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
        if (fd < 0) return error.ConnectionFailed;
        defer _ = c.close(fd);
        var address = std.mem.zeroes(c.sockaddr.un);
        address.family = c.AF.UNIX;
        if (self.socket_path.len >= address.path.len) return error.ConnectionFailed;
        @memcpy(address.path[0..self.socket_path.len], self.socket_path);
        const address_length: c.socklen_t = @intCast(@offsetOf(c.sockaddr.un, "path") + self.socket_path.len + 1);
        if (c.connect(fd, @ptrCast(&address), address_length) < 0) return error.ConnectionFailed;
        const timeout: c.timeval = .{ .sec = 0, .usec = 100_000 };
        if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVTIMEO, &timeout, @sizeOf(c.timeval)) != 0) return error.ConnectionFailed;
        if (c.setsockopt(fd, c.SOL.SOCKET, c.SO.SNDTIMEO, &timeout, @sizeOf(c.timeval)) != 0) return error.ConnectionFailed;

        const payload = "\"" ++ name ++ "\"\n";
        var sent: usize = 0;
        while (sent < payload.len) {
            const count = c.send(fd, payload[sent..].ptr, payload.len - sent, c.MSG.NOSIGNAL);
            if (count <= 0) return error.SendFailed;
            sent += @intCast(count);
        }
        var buffer: [128 * 1024]u8 = undefined;
        var length: usize = 0;
        while (length < buffer.len) {
            const count = c.read(fd, buffer[length..].ptr, buffer.len - length);
            if (count < 0) return error.ReceiveFailed;
            if (count == 0) return error.InvalidResponse;
            const previous_length = length;
            length += @intCast(count);
            if (std.mem.indexOfScalar(u8, buffer[previous_length..length], '\n')) |end| {
                return self.parse(T, buffer[0 .. previous_length + end]);
            }
        }
        return error.ResponseTooLarge;
    }

    fn parse(self: *const Client, comptime T: type, response: []const u8) !T {
        const envelope = std.json.parseFromSliceLeaky(struct { Ok: ?T = null, Err: ?[]const u8 = null }, self.allocator, response, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.InvalidResponse;
        if (envelope.Err != null) return error.NiriError;
        return envelope.Ok orelse error.InvalidResponse;
    }
};

test "typed IPC parsing owns strings and rejects malformed window data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const client = Client{ .allocator = arena.allocator(), .socket_path = "unused" };
    const Result = struct { Windows: []Window };
    const json =
        \\{"Ok":{"Windows":[{"id":3,"title":"a\"b","app_id":"ghostty","pid":10,
        \\"is_focused":true,"is_floating":false,"is_urgent":false,"layout":{
        \\"tile_size":[100.4,200.4],"window_size":[100,200],
        \\"window_offset_in_tile":[0,0],"tile_pos_in_workspace_view":null}}]}}
    ;
    const result = try client.parse(Result, json);
    try std.testing.expectEqualStrings("a\"b", result.Windows[0].title.?);
    try std.testing.expectEqual(@as(i32, 100), result.Windows[0].layout.window_size[0]);
    try std.testing.expectError(error.InvalidResponse, client.parse(Result, "{\"Ok\":{\"Windows\":[{\"id\":3}]}}"));
    try std.testing.expectError(error.NiriError, client.parse(Result, "{\"Err\":\"unavailable\"}"));
}
