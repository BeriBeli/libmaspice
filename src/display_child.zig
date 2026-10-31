//! Display vertical slice for Supervisor. Explicitly rejects other channel kinds;
//! the full multi-service bundle is separate work, never a passive fallback.
const std = @import("std");
const display = @import("display.zig");
const service = @import("display_service.zig");
const clock = @import("clock.zig");
const barrier = @import("barrier.zig");
const channel = @import("channel.zig");
const cancel = @import("cancel.zig");
const wire = @import("bytes.zig");
const graphics = @import("graphics.zig");
pub const Diagnostics = service.Metrics;
pub const Event = service.Event;
pub const World = struct {
    allocator: std.mem.Allocator,
    shared: *display.World,
    media: *clock.Clock,
    native: ?graphics.Context = null,
    pub const Configuration = struct {
        native: ?graphics.Context = null,
        pub fn retain(self: Configuration) Configuration {
            return .{ .native = if (self.native) |context| context.retain() else null };
        }
        pub fn deinit(self: Configuration) void {
            if (self.native) |context| context.deinit();
        }
    };
    pub fn create(a: std.mem.Allocator, media: *clock.Clock) !*World {
        return createConfigured(a, media, .{});
    }
    pub fn createConfigured(a: std.mem.Allocator, media: *clock.Clock, configuration: Configuration) !*World {
        const self = try a.create(World);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .shared = try display.World.create(a), .media = media };
        self.native = if (configuration.native) |context| context.retain() else null;
        return self;
    }
    pub fn memorySnapshot(self: *World) struct { used: usize, maximum: usize } {
        return .{ .used = self.shared.surface_memory.allocated(), .maximum = self.shared.surface_memory.maximum };
    }
    pub fn destroy(self: *World) void {
        self.shared.destroy();
        if (self.native) |context| context.deinit();
        self.allocator.destroy(self);
    }
};
pub const State = struct {
    allocator: std.mem.Allocator,
    display: *service.Service,
    pub const Sink = service.Sink;
    pub fn create(a: std.mem.Allocator, world: *World, key: barrier.Key) !*State {
        if (key.kind != 2) return error.UnsupportedChannel;
        const self = try a.create(State);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .display = try service.Service.create(a, world.shared, world.media, world.native) };
        return self;
    }
    pub fn videoFailure(self: *State, failure: anyerror) ?@import("video_failure.zig").Failure {
        return self.display.streams.videoFailure(failure);
    }
    pub fn diagnosticsSnapshot(self: *State) Diagnostics {
        return self.display.metrics();
    }
    pub fn destroy(self: *State) void {
        self.display.destroy();
        self.allocator.destroy(self);
    }
    pub fn bind(self: *State, sink: Sink, token: *cancel.Token) !void {
        try self.display.bind(sink, token);
    }
    pub fn unbind(self: *State) void {
        self.display.unbind();
    }
    pub fn step(self: *State, connection: *channel.Channel, token: *cancel.Token) !union(enum) { processed, event: Event, migration: ?wire.Slice } {
        return switch (try self.display.step(connection, token)) {
            .migration => |payload| .{ .migration = payload },
            .event => |event| blk: {
                if (event == .drawing and event.drawing == .ignored) break :blk .processed;
                break :blk .{ .event = event };
            },
        };
    }
};
