//! Complete dispatcher for the existing Display draw/stream/monitor subset.
//! A stable heap service owns its joined codec scheduler and Surface store.
//! Advanced frames are drained before physical completion, matching Swift's
//! reference-frame boundary; MJPEG receives continue with latest-pending policy.
const std = @import("std");
const display = @import("display.zig");
const stream = @import("stream_wire.zig");
const scheduler = @import("stream_scheduler.zig");
const publisher = @import("frame_publisher.zig");
const cancel = @import("cancel.zig");
const wire = @import("bytes.zig");
const surface = @import("surface.zig");
const clock = @import("clock.zig");
const graphics = @import("graphics.zig");
const channel = @import("channel.zig");
pub const Event = union(enum) {
    drawing: display.Event,
    publication: publisher.Published,
    monitors: struct { allocator: std.mem.Allocator, maximum: u16, heads: []stream.Monitor },
    pub fn deinit(self: Event) void {
        switch (self) {
            .drawing => |event| event.deinit(),
            .publication => |event| event.deinit(),
            .monitors => |m| m.allocator.free(m.heads),
        }
    }
    pub fn weight(self: Event) usize {
        return switch (self) {
            .drawing => 0,
            .publication => |event| event.weight(),
            .monitors => |m| m.heads.len * @sizeOf(stream.Monitor),
        };
    }
};
pub const Sink = struct { context: *anyopaque, event: *const fn (*anyopaque, Event, *cancel.Token) anyerror!void, fail: *const fn (*anyopaque, anyerror, *cancel.Token) void };
pub const Metrics = struct {
    display_channels: u64 = 0,
    surfaces: surface.diagnostics.Metrics = .{},
    publisher: publisher.Metrics = .{},
    streams: @import("stream_decoder.zig").Metrics = .{},
    // Canonical Surface memory is sampled separately from the active World.
    surface_bytes: usize = 0,
    maximum_surface_bytes: usize = 0,
    pub fn accumulate(self: *Metrics, other: Metrics) void {
        self.display_channels +|= other.display_channels;
        self.surfaces.accumulate(other.surfaces);
        self.publisher.accumulate(other.publisher);
        self.streams.accumulate(other.streams);
    }
};
pub const Service = struct {
    allocator: std.mem.Allocator,
    core: display.State,
    streams: *scheduler.Scheduler,
    frames: *publisher.Publisher,
    timebase: std.c.mach_timebase_info_data,
    sink: ?Sink = null,
    parent: ?*cancel.Token = null,
    registration: cancel.Registration = undefined,
    pub fn create(a: std.mem.Allocator, world: *display.World, media: ?*clock.Clock, native: ?graphics.Context) !*Service {
        var timebase: std.c.mach_timebase_info_data = undefined;
        if (std.c.mach_timebase_info(&timebase) != 0 or timebase.denom == 0) return error.ClockUnavailable;
        const self = try a.create(Service);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .core = display.State.init(a, world, native), .streams = undefined, .frames = undefined, .timebase = timebase };
        errdefer self.core.deinit();
        self.streams = try scheduler.Scheduler.create(a, &self.core.surfaces, &world.executor, media, .{});
        errdefer self.streams.destroy();
        self.frames = try publisher.Publisher.create(a, .{ .context = self, .snapshot = prepareFrame }, .{ .interval_ns = 0, .requires_demand = true, .waits_consumption = true });
        return self;
    }
    /// Each component is synchronized; the combined sample is best effort.
    pub fn metrics(self: *Service) Metrics {
        return .{ .display_channels = 1, .surfaces = self.core.surfaces.metrics(), .publisher = self.frames.metrics(), .streams = self.streams.metrics() };
    }
    pub fn destroy(self: *Service) void {
        self.unbind();
        self.streams.destroy();
        self.frames.destroy();
        self.core.deinit();
        self.allocator.destroy(self);
    }
    fn publish(p: *anyopaque, revision: surface.Revision, timing: ?publisher.Timing, token: *cancel.Token) !void {
        const self: *Service = @ptrCast(@alignCast(p));
        try token.check();
        try self.frames.submit(revision, timing);
        const sink = self.sink.?;
        try sink.event(sink.context, .{ .drawing = .{ .frame = revision } }, token);
    }
    fn prepareFrame(p: *anyopaque, revision: surface.Revision, token: *cancel.Token) !?surface.Publication {
        const self: *Service = @ptrCast(@alignCast(p));
        try token.check();
        const frame = try self.core.surfaces.publicationSnapshot(revision);
        errdefer if (frame) |v| v.release();
        try token.check();
        return frame;
    }
    fn emitFrame(p: *anyopaque, frame: publisher.Published, token: *cancel.Token) !void {
        const self: *Service = @ptrCast(@alignCast(p));
        const sink = self.sink.?;
        try sink.event(sink.context, .{ .publication = frame }, token);
    }
    fn cancelAll(p: *anyopaque) void {
        const self: *Service = @ptrCast(@alignCast(p));
        self.streams.cancelRun();
        self.frames.cancelRun();
    }
    fn fail(p: *anyopaque, err: anyerror, token: *cancel.Token) void {
        const self: *Service = @ptrCast(@alignCast(p));
        const sink = self.sink.?;
        sink.fail(sink.context, err, token);
    }
    pub fn bind(self: *Service, sink: Sink, parent: *cancel.Token) !void {
        if (self.parent != null) return error.AlreadyBound;
        self.sink = sink;
        errdefer self.sink = null;
        try self.streams.bind(.{ .context = self, .publish = publish, .fail = fail });
        errdefer self.streams.unbind();
        try self.frames.bind(.{ .context = self, .emit = emitFrame, .fail = fail });
        self.parent = parent;
        self.registration = .{ .context = self, .wake = cancelAll };
        parent.register(&self.registration);
    }
    pub fn unbind(self: *Service) void {
        if (self.parent) |parent| {
            parent.unregister(&self.registration);
            self.parent = null;
            cancelAll(self);
            self.streams.unbind();
            self.frames.unbind();
            self.sink = null;
        }
    }
    pub fn step(self: *Service, connection: *channel.Channel, token: *cancel.Token) !union(enum) { event: Event, migration: ?wire.Slice } {
        try token.check();
        try self.core.initialize(connection);
        const input = connection.receive() catch |err| {
            return self.streams.currentFailure() orelse err;
        };
        switch (input) {
            .migration => |payload| return .{ .migration = payload },
            .message => |message| {
                defer message.deinit();
                const event = try self.handle(connection, message.kind, message.body, token);
                errdefer event.deinit();
                try connection.complete();
                return .{ .event = event };
            },
        }
    }
    pub fn handle(self: *Service, connection: *channel.Channel, kind: u16, body: wire.Slice, token: *cancel.Token) !Event {
        const received_ns = clock.nanoseconds(self.timebase);
        try token.check();
        if (try @import("channel_control.zig").handle(self.allocator, connection, kind, body.bytes())) return .{ .drawing = .{ .ignored = kind } };
        switch (kind) {
            122...126, 316, 317, 319 => {
                var parsed = try stream.decode(self.allocator, kind, body.bytes());
                defer parsed.deinit();
                switch (parsed.command) {
                    .create => |value| try self.streams.add(value),
                    .clip => |value| try self.streams.setClip(value.id, value.clips),
                    .destroy => |id| try self.streams.remove(id),
                    .destroy_all => self.streams.removeAll(),
                    .report => |value| try self.streams.activateReport(value),
                    .monitors => |value| return .{ .monitors = .{ .allocator = self.allocator, .maximum = value.maximum, .heads = try self.allocator.dupe(stream.Monitor, value.heads) } },
                    .data => |value| {
                        const payload = try body.subslice(@intFromPtr(value.bytes.ptr) - @intFromPtr(body.bytes().ptr), value.bytes.len);
                        defer payload.release();
                        const report = try self.streams.submitTimed(value.id, payload, value.time, value.sizing, received_ns / 1_000_000, received_ns);
                        if (report) |result| {
                            var output: wire.Writer = .{ .allocator = self.allocator, .limit = 32 };
                            defer output.deinit();
                            try result.encode(&output);
                            try connection.send(102, output.bytes.items);
                        }
                        // Existing Swift executes advanced frames before completing
                        // their physical batch. Preserve that migration contract.
                        if (try self.streams.codec(value.id) != .mjpeg) try self.streams.drain();
                    },
                }
                return .{ .drawing = .{ .ignored = kind } };
            },
            315 => {
                var reader = try wire.Reader.init(body.bytes(), 0);
                const id = try reader.read(u32);
                try reader.finish();
                self.streams.removeSurface(id);
            },
            103 => {
                if (body.bytes().len != 0) return error.TrailingBytes;
                self.streams.removeAll();
            },
            else => {},
        }
        const result = try self.core.handle(kind, body.bytes(), body.retainedBytes(), connection.barrier, token);
        switch (result) {
            .frame => |revision| try self.frames.submit(revision, .{ .received_ns = received_ns, .ready_ns = clock.nanoseconds(self.timebase) }),
            .destroyed => |id| try self.frames.remove(id),
            else => {},
        }
        return .{ .drawing = result };
    }
};
