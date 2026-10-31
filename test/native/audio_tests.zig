const std = @import("std");
const s = @import("spice");
const t = std.testing;
const start = s.audio_wire.Start{ .configuration = .{ .channels = 2, .frequency = 48000 }, .time = 100 };
fn playback(a: std.mem.Allocator) !void {
    var media = try s.clock.Clock.init();
    defer media.deinit();
    var state = s.audio.Playback.init(a, &media);
    defer state.deinit();
    try t.expectError(error.AudioModeRequired, state.apply(.{ .start = start }));
    try t.expectError(error.UnsupportedAudioMode, state.apply(.{ .mode = .{ .time = 100, .kind = 3, .bytes = &.{} } }));
    (try state.apply(.{ .mode = .{ .time = 100, .kind = 1, .bytes = &.{} } })).deinit();
    (try state.apply(.{ .start = start })).deinit();
    try t.expectError(error.NoAudioData, state.reportDelay(20));
    try t.expectError(error.MisalignedPCM, state.apply(.{ .packet = .{ .time = 120, .bytes = &.{ 1, 2 } } }));
    const packet = try state.apply(.{ .packet = .{ .time = 120, .bytes = &.{ 1, 2, 3, 4 } } });
    defer packet.deinit();
    try state.reportDelay(20);
    try t.expectEqual(@as(?u32, 20), media.playbackDelay());
    (try state.apply(.stop)).deinit();
    try t.expectEqual(@as(?u32, null), media.playbackDelay());
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, packet.packet.data.bytes());
}
test "RAW playback ordering alignment actual delay stop and allocation failure ownership" {
    try t.checkAllAllocationFailures(t.allocator, playback, .{});
}
const Sender = struct {
    bodies: std.ArrayList(u8) = .empty,
    kinds: std.ArrayList(u16) = .empty,
    fail_mark: bool = false,
    cancelled: bool = false,
    pub fn send(self: *Sender, id: u16, body: []const u8) !void {
        if (self.fail_mark and id == 103) return error.InjectedFailure;
        try self.kinds.append(t.allocator, id);
        try self.bodies.appendSlice(t.allocator, body);
    }
    pub fn cancel(self: *Sender) void {
        self.cancelled = true;
    }
    fn deinit(self: *Sender) void {
        self.bodies.deinit(t.allocator);
        self.kinds.deinit(t.allocator);
    }
};
test "Record MODE START_MARK PCM ordering and partial begin failure cancels transport" {
    var state = s.audio.Record.init(t.allocator);
    defer state.deinit();
    var sender: Sender = .{};
    defer sender.deinit();
    try t.expectError(error.AudioStopped, state.send(&sender, .{ .begin = 10 }));
    (try state.apply(.{ .start = start })).deinit();
    try t.expectError(error.AudioMarkRequired, state.send(&sender, .{ .packet = .{ .time = 11, .bytes = &.{ 1, 2, 3, 4 } } }));
    try state.send(&sender, .{ .begin = 10 });
    try state.send(&sender, .{ .packet = .{ .time = 11, .bytes = &.{ 1, 2, 3, 4 } } });
    try t.expectEqualSlices(u16, &.{ 102, 103, 101 }, sender.kinds.items);
    try t.expectEqualSlices(u8, &.{ 10, 0, 0, 0, 1, 0, 10, 0, 0, 0, 11, 0, 0, 0, 1, 2, 3, 4 }, sender.bodies.items);
    try t.expectError(error.AudioAlreadyMarked, state.send(&sender, .{ .begin = 10 }));
    (try state.apply(.stop)).deinit();
    (try state.apply(.{ .start = start })).deinit();
    sender.fail_mark = true;
    try t.expectError(error.InjectedFailure, state.send(&sender, .{ .begin = 20 }));
    try t.expect(sender.cancelled);
}
test "audio wire enums exact framing limits and channel configuration" {
    const body = [_]u8{ 2, 0, 0, 0, 1, 0, 128, 187, 0, 0, 100, 0, 0, 0 };
    const parsed = try s.audio_wire.playback(103, &body);
    try t.expectEqual(start, parsed.start);
    for (0..body.len) |end| {
        if (s.audio_wire.playback(103, body[0..end])) |_| return error.AcceptedTruncation else |_| {}
    }
    try t.expectError(error.TrailingBytes, s.audio_wire.record(101, &body));
    try t.expectError(error.InvalidSize, s.audio_wire.playback(105, &.{ 2, 100, 0 }));
    try t.expectError(error.InvalidEnum, s.audio_wire.record(104, &.{2}));
    try t.expectError(error.InvalidAudioConfiguration, s.audio_wire.validate(.{ .channels = 0, .frequency = 48000 }));
    try t.expectError(error.InvalidAudioConfiguration, s.audio_wire.validate(.{ .channels = 2, .frequency = 7999 }));
}

test "record START epoch rejects stale begin and PCM before any wire output" {
    var state = s.audio.Record.init(t.allocator);
    defer state.deinit();
    var sender: Sender = .{};
    defer sender.deinit();
    const first = try state.apply(.{ .start = start });
    try t.expect(first.start.epoch > 0);
    try state.sendAt(&sender, .{ .begin = 10 }, first.start.epoch);
    (try state.apply(.stop)).deinit();
    const second = try state.apply(.{ .start = start });
    try t.expect(second.start.epoch > first.start.epoch);
    const before = sender.kinds.items.len;
    try t.expectError(error.AudioStreamChanged, state.sendAt(&sender, .{ .begin = 20 }, first.start.epoch));
    try t.expectError(error.AudioStreamChanged, state.sendAt(&sender, .{ .packet = .{ .time = 21, .bytes = &.{ 1, 2, 3, 4 } } }, first.start.epoch));
    try t.expectEqual(before, sender.kinds.items.len);
    try state.sendAt(&sender, .{ .begin = 22 }, second.start.epoch);
}
const BlockingAudioSend = struct {
    mutex: s.sync.Mutex = .{},
    changed: s.sync.Condition = .{},
    cancelled: bool = false,
    entered: std.atomic.Value(bool) = .init(false),
    result: ?anyerror = null,
    pub fn send(self: *@This(), _: u16, _: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.entered.store(true, .release);
        while (!self.cancelled) self.changed.wait(&self.mutex);
        return error.ConnectionClosed;
    }
    pub fn cancel(self: *@This()) void {
        self.mutex.lock();
        self.cancelled = true;
        self.changed.broadcast();
        self.mutex.unlock();
    }
    fn run(connection: *s.audio_send.Cancellable(@This())) void {
        connection.send(101, &.{ 1, 2 }) catch |err| {
            connection.connection.result = err;
        };
    }
};
extern "c" fn usleep(c_uint) c_int;
test "record per-write cancellation joins exact transport and precancel leaves idle transport open" {
    var send: BlockingAudioSend = .{};
    defer send.mutex.deinit();
    defer send.changed.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var connection: s.audio_send.Cancellable(BlockingAudioSend) = .{ .connection = &send, .token = &token };
    const worker = try std.Thread.spawn(.{}, BlockingAudioSend.run, .{&connection});
    var joined = false;
    defer if (!joined) {
        token.cancel();
        worker.join();
    };
    for (0..3000) |_| {
        if (send.entered.load(.acquire)) break;
        _ = usleep(1000);
    }
    try t.expect(send.entered.load(.acquire));
    token.cancel();
    worker.join();
    joined = true;
    try t.expectEqual(error.ConnectionClosed, send.result.?);
    var idle: BlockingAudioSend = .{};
    defer idle.mutex.deinit();
    defer idle.changed.deinit();
    connection.connection = &idle;
    try t.expectError(error.Cancelled, connection.send(101, &.{}));
    try t.expect(!idle.cancelled and !idle.entered.load(.acquire));
}
