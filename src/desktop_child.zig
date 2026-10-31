//! Concrete desktop channels. Unimplemented channel kinds fail explicitly.
//! Service objects survive handoff; only their connection-bound sinks rebind.
const std = @import("std");
const service = @import("display_service.zig");
const inputs = @import("inputs.zig");
const audio = @import("audio.zig");
const audio_wire = @import("audio_wire.zig");
const card = @import("smartcard.zig");
const card_wire = @import("smartcard_wire.zig");
const vmc = @import("vmc.zig");
const webdav = @import("webdav.zig");
const cursor = @import("cursor.zig");
const cursor_wire = @import("cursor_wire.zig");
const channel = @import("channel.zig");
const cancel = @import("cancel.zig");
const wire = @import("bytes.zig");
const barrier = @import("barrier.zig");
pub const World = @import("display_child.zig").World;
pub const Diagnostics = service.Metrics;
pub const Event = union(enum) {
    display: service.Event,
    inputs: inputs.Event,
    cursor: cursor.Event,
    playback: audio.Event,
    record: audio.Event,
    smartcard: card.Event,
    usb: wire.Slice,
    webdav: webdav.Event,
    pub fn deinit(self: Event) void {
        switch (self) {
            .display => |v| v.deinit(),
            .cursor => |v| v.deinit(),
            .playback, .record => |v| v.deinit(),
            .smartcard => |v| v.deinit(),
            .usb => |v| v.release(),
            .webdav => |v| v.deinit(),
            .inputs => {},
        }
    }
    pub fn weight(self: Event) usize {
        return switch (self) {
            .display => |v| v.weight(),
            .cursor => |v| v.weight(),
            .playback, .record => |v| v.weight(),
            .smartcard => |v| v.weight(),
            .usb => |v| v.retainedBytes(),
            .webdav => |v| v.weight(),
            .inputs => 0,
        };
    }
};
pub const State = struct {
    allocator: std.mem.Allocator,
    value: union(enum) { display: *service.Service, inputs: inputs.State, cursor: cursor.State, playback: audio.Playback, record: audio.Record, smartcard: card.State, usb, webdav: webdav.State },
    sink: ?Sink = null,
    pub const Sink = struct { context: *anyopaque, event: *const fn (*anyopaque, Event, *cancel.Token) anyerror!void, fail: *const fn (*anyopaque, anyerror, *cancel.Token) void };
    pub fn create(a: std.mem.Allocator, world: *World, key: barrier.Key) !*State {
        const self = try a.create(State);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .value = switch (key.kind) {
            2 => .{ .display = try service.Service.create(a, world.shared, world.media, world.native) },
            3 => .{ .inputs = .{} },
            4 => .{ .cursor = cursor.State.init(a) },
            5 => .{ .playback = audio.Playback.init(a, world.media) },
            6 => .{ .record = audio.Record.init(a) },
            8 => .{ .smartcard = card.State.init(a) },
            9 => .usb,
            11 => .{ .webdav = webdav.State.init(a) },
            else => return error.UnsupportedChannel,
        } };
        return self;
    }
    pub fn videoFailure(self: *State, failure: anyerror) ?@import("video_failure.zig").Failure {
        return switch (self.value) {
            .display => |display| display.streams.videoFailure(failure),
            else => null,
        };
    }
    pub fn diagnosticsSnapshot(self: *State) Diagnostics {
        return switch (self.value) {
            .display => |value| value.metrics(),
            else => .{},
        };
    }
    pub fn destroy(self: *State) void {
        self.unbind();
        switch (self.value) {
            .display => |v| v.destroy(),
            .cursor => |*v| v.deinit(),
            .inputs => |*v| v.deinit(),
            .playback => |*v| v.deinit(),
            .record => |*v| v.deinit(),
            .smartcard => |*v| v.deinit(),
            .webdav => |*v| v.deinit(),
            .usb => {},
        }
        self.allocator.destroy(self);
    }
    fn publish(context: *anyopaque, event: service.Event, token: *cancel.Token) !void {
        const self: *State = @ptrCast(@alignCast(context));
        const sink = self.sink.?;
        try sink.event(sink.context, .{ .display = event }, token);
    }
    fn fail(context: *anyopaque, err: anyerror, token: *cancel.Token) void {
        const self: *State = @ptrCast(@alignCast(context));
        const sink = self.sink.?;
        sink.fail(sink.context, err, token);
    }
    pub fn bind(self: *State, sink: Sink, token: *cancel.Token) !void {
        if (self.sink != null) return error.AlreadyBound;
        self.sink = sink;
        errdefer self.sink = null;
        if (self.value == .display) try self.value.display.bind(.{ .context = self, .event = publish, .fail = fail }, token);
    }
    pub fn unbind(self: *State) void {
        if (self.value == .display) self.value.display.unbind();
        self.sink = null;
    }
    pub fn sendInput(self: *State, connection: *channel.Channel, input: inputs.Input) !void {
        if (self.value != .inputs) return error.UnsupportedChannel;
        try self.value.inputs.send(connection, input);
    }
    pub fn sendRecord(self: *State, connection: *channel.Channel, input: audio.RecordInput) !void {
        if (self.value != .record) return error.UnsupportedChannel;
        try self.value.record.send(connection, input);
    }
    pub fn sendRecordAt(self: *State, connection: anytype, input: audio.RecordInput, epoch: u64) !void {
        if (self.value != .record) return error.UnsupportedChannel;
        try self.value.record.sendAt(connection, input, epoch);
    }
    pub fn reportPlaybackDelay(self: *State, delay: u32) !void {
        if (self.value != .playback) return error.UnsupportedChannel;
        try self.value.playback.reportDelay(delay);
    }
    pub fn sendSmartcard(self: *State, connection: *channel.Channel, message: card_wire.Message) !void {
        if (self.value != .smartcard) return error.UnsupportedChannel;
        try self.value.smartcard.send(connection, message);
    }
    pub fn sendUSB(self: *State, connection: anytype, bytes: []const u8) !void {
        if (self.value != .usb) return error.UnsupportedChannel;
        try vmc.send(connection, bytes);
    }
    pub fn sendWebDAV(self: *State, connection: anytype, client: i64, bytes: []const u8) !void {
        if (self.value != .webdav) return error.UnsupportedChannel;
        try self.value.webdav.send(connection, client, bytes);
    }
    pub fn setFrameDemand(self: *State, id: u32, demanded: bool) !void {
        if (self.value != .display) return error.UnsupportedChannel;
        try self.value.display.frames.setDemand(id, demanded);
    }
    pub fn acknowledgeFrame(self: *State, revision: @import("surface.zig").Revision) !void {
        if (self.value != .display) return error.UnsupportedChannel;
        self.value.display.frames.acknowledge(revision);
    }
    pub fn flushFrames(self: *State) !void {
        if (self.value != .display) return error.UnsupportedChannel;
        try self.value.display.frames.flushNow();
    }
    pub fn frameMetrics(self: *State) !@import("frame_publisher.zig").Metrics {
        if (self.value != .display) return error.UnsupportedChannel;
        return self.value.display.frames.metrics();
    }
    pub fn step(self: *State, connection: *channel.Channel, token: *cancel.Token) !union(enum) { processed, event: Event, migration: ?wire.Slice } {
        try token.check();
        if (self.value == .display) return switch (try self.value.display.step(connection, token)) {
            .migration => |payload| .{ .migration = payload },
            .event => |event| if (event == .drawing and event.drawing == .ignored) .processed else .{ .event = .{ .display = event } },
        };
        if (self.value == .webdav) {
            if (try self.value.webdav.next()) |event| return .{ .event = .{ .webdav = event } };
        }
        switch (try connection.receive()) {
            .migration => |payload| return .{ .migration = payload },
            .message => |message| {
                defer message.deinit();
                const event = try self.handle(connection, message.kind, message.body.bytes());
                errdefer if (event) |v| v.deinit();
                try connection.complete();
                return if (event) |v| .{ .event = v } else .processed;
            },
        }
    }
    fn handle(self: *State, connection: *channel.Channel, kind: u16, bytes: []const u8) !?Event {
        if (try @import("channel_control.zig").handle(self.allocator, connection, kind, bytes)) return null;
        // Only return a fully constructed event. An errdefer in the caller must
        // never see a result-location union whose fallible payload is incomplete.
        return switch (self.value) {
            .inputs => if (try self.value.inputs.receive(kind, bytes)) |v| .{ .inputs = v } else null,
            .cursor => |*state| if (kind >= 101 and kind <= 108) .{ .cursor = try state.apply(try cursor_wire.decode(kind, bytes)) } else null,
            .playback => |*state| if (kind >= 101 and kind <= 107) .{ .playback = try state.apply(try audio_wire.playback(kind, bytes)) } else null,
            .record => |*state| if (kind >= 101 and kind <= 104) .{ .record = try state.apply(try audio_wire.record(kind, bytes)) } else null,
            .smartcard => |*state| if (kind == 101) .{ .smartcard = try state.apply(connection, try card_wire.decode(bytes)) } else null,
            .usb => .{ .usb = try vmc.decode(self.allocator, kind, bytes) },
            .webdav => |*state| if (try state.handle(kind, bytes)) |v| .{ .webdav = v } else null,
            .display => unreachable,
        };
    }
};
