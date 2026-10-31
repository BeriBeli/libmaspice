//! Bounded monitor layout validation and one-in-flight reply coordination.
const std = @import("std");
const protocol = @import("agent_services_wire.zig");
const clipboard = @import("clipboard.zig");
pub const Monitor = struct { id: i64, x: i64 = 0, y: i64 = 0, width: i64, height: i64 };
pub const Configuration = struct {
    monitors: [256]Monitor = undefined,
    count: usize = 0,
    pub fn init(monitors: []const Monitor) !Configuration {
        if (monitors.len == 0 or monitors.len > 256) return error.InvalidLayout;
        var result: Configuration = .{ .count = monitors.len };
        @memcpy(result.monitors[0..monitors.len], monitors);
        return result;
    }
    pub fn encode(self: Configuration, support: clipboard.Support) !Wire {
        if (self.count == 0 or self.count > 256) return error.InvalidLayout;
        var indexed: [256]?Monitor = @splat(null);
        var maximum: usize = 0;
        var enabled = false;
        var positions = false;
        for (self.monitors[0..self.count]) |m| {
            if (m.id < 0 or m.id >= 256) return error.InvalidLayout;
            const id: usize = @intCast(m.id);
            if (indexed[id] != null) return error.InvalidLayout;
            if (!(m.width > 0 and m.height > 0) and !(m.width == 0 and m.height == 0)) return error.InvalidDimensions;
            if (std.math.cast(u32, m.width) == null or std.math.cast(u32, m.height) == null or std.math.cast(i32, m.x) == null or std.math.cast(i32, m.y) == null) return error.InvalidLayout;
            if (m.width == 0 and (m.x != 0 or m.y != 0)) return error.InvalidLayout;
            indexed[id] = m;
            maximum = @max(maximum, id);
            enabled = enabled or m.width > 0;
            positions = positions or (m.width > 0 and (m.x != 0 or m.y != 0));
        }
        if (!enabled) return error.InvalidLayout;
        var result: Wire = .{ .count = maximum + 1, .positions = positions };
        for (indexed[0..result.count], result.monitors[0..result.count]) |entry, *out| {
            const m = entry orelse Monitor{ .id = 0, .width = 0, .height = 0 };
            result.sparse = result.sparse or m.width == 0;
            out.* = .{ .width = @intCast(m.width), .height = @intCast(m.height), .depth = 32, .x = @intCast(m.x), .y = @intCast(m.y) };
        }
        if (support.explicit and ((result.sparse and !support.sparse) or (positions and !support.positions))) return error.UnsupportedMonitorConfiguration;
        return result;
    }
};
pub const Wire = struct {
    monitors: [256]protocol.Monitor = undefined,
    count: usize,
    positions: bool,
    sparse: bool = false,
    pub fn message(self: Wire, a: std.mem.Allocator) !@import("agent.zig").Message {
        if (self.count > 256) return error.InvalidSize;
        return protocol.encodeMonitors(a, self.monitors[0..self.count], self.positions, self.sparse);
    }
};
pub const Request = struct { id: u64, configuration: Configuration };
pub const Coordinator = struct {
    desired: ?Request = null,
    in_flight: ?Request = null,
    next_id: u64 = 0,
    pub fn queue(self: *Coordinator, configuration: Configuration) !Request {
        if (configuration.count == 0 or configuration.count > 256) return error.InvalidLayout;
        const id = try std.math.add(u64, self.next_id, 1);
        const request: Request = .{ .id = id, .configuration = configuration };
        self.next_id = id;
        self.desired = request;
        return request;
    }
    pub fn next(self: Coordinator) ?Request {
        return if (self.in_flight == null) self.desired else null;
    }
    pub fn didSend(self: *Coordinator, id: u64) bool {
        const request = self.next() orelse return false;
        if (request.id != id) return false;
        self.in_flight = request;
        self.desired = null;
        return true;
    }
    pub fn reply(self: *Coordinator) ?Request {
        const result = self.in_flight;
        self.in_flight = null;
        return result;
    }
    pub fn disconnected(self: *Coordinator) void {
        if (self.desired == null) self.desired = self.in_flight;
        self.in_flight = null;
    }
    pub fn discardDesired(self: *Coordinator) void {
        self.desired = null;
    }
    pub fn reset(self: *Coordinator) void {
        self.desired = null;
        self.in_flight = null;
    }
};
