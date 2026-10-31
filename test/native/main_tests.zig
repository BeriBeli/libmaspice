const std = @import("std");
const t = std.testing;
const s = @import("spice");
const a = t.allocator;
const helpers = @import("channel_tests.zig");
const main_key: s.barrier.Key = .{ .kind = 1, .id = 0 };
const Clock = struct {
    last: u32 = 0,
    resets: u32 = 0,
    fn reset(ctx: *anyopaque, value: u32) void {
        const self: *Clock = @ptrCast(@alignCast(ctx));
        self.last = value;
        self.resets += 1;
    }
    fn adapter(self: *Clock) s.main_channel.Clock {
        return .{ .context = self, .reset = reset };
    }
};
fn generated(output: *s.bytes.Writer, message: anytype) !void {
    var body: s.bytes.Writer = .{ .allocator = a, .limit = 4096 };
    defer body.deinit();
    try message.encode(&body);
    try helpers.frame(output, null, @TypeOf(message).message_id.?, body.bytes.items);
}
fn initMessage(output: *s.bytes.Writer, connected: bool, tokens: u32) !void {
    try generated(output, s.protocol.SpiceMsgMainInit{ .sessionID = 1234, .displayChannelsHint = 1, .supportedMouseModes = 3, .currentMouseMode = 1, .agentConnected = @intFromBool(connected), .agentTokens = tokens, .multimediaTime = 100, .ramHint = 0 });
}
fn listMessage(output: *s.bytes.Writer) !void {
    try helpers.frame(output, null, 104, &.{ 2, 0, 0, 0, 2, 0, 3, 1 });
}
fn agentBytes(output: *s.bytes.Writer, kind: u32, data: []const u8) !void {
    try output.write(u32, 1);
    try output.write(u32, kind);
    try output.write(u64, 123);
    try output.write(u32, @intCast(data.len));
    try output.append(data);
}
test "Main bootstrap requests client mouse, starts Agent, handles padded ping ACK clock and retained Agent data" {
    var input: s.bytes.Writer = .{ .allocator = a, .limit = 65536 };
    defer input.deinit();
    try initMessage(&input, true, 2);
    try generated(&input, s.protocol.SpiceMsgSetAck{ .generation = 8, .window = 1 });
    try helpers.frame(&input, null, 4, &.{ 9, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0xaa, 0xbb });
    try generated(&input, s.protocol.SpiceMsgMainMultimediaTime{ .multimediaTime = 200 });
    try generated(&input, s.protocol.SpiceMsgMainMouseMode{ .supportedModes = 3, .currentMode = 2 });
    var stream: s.bytes.Writer = .{ .allocator = a, .limit = 1024 };
    defer stream.deinit();
    try agentBytes(&stream, 4, "clipboard");
    try helpers.frame(&input, null, 109, stream.bytes.items[0..13]);
    try helpers.frame(&input, null, 109, stream.bytes.items[13..]);
    try listMessage(&input);
    const barrier = try s.barrier.Barrier.create(a);
    defer barrier.destroy();
    var fake: helpers.Fake = .{ .input = input.bytes.items };
    defer fake.output.deinit();
    var channel = s.channel.Channel.init(a, main_key, fake.io(), .mini, barrier);
    defer channel.deinit();
    var clock: Clock = .{};
    var main = s.main_channel.Main.init(a, &channel, clock.adapter());
    const bootstrap = try main.bootstrap();
    defer bootstrap.deinit();
    try t.expectEqual(@as(u32, 1234), bootstrap.session_id);
    try t.expectEqual(@as(u32, 2), bootstrap.mouse.current);
    try t.expectEqual(@as(u32, 200), clock.last);
    try t.expectEqual(@as(u32, 2), clock.resets);
    try t.expectEqual(@as(usize, 2), bootstrap.channels.len);
    try t.expect(bootstrap.agent_connected);
    const event = (try main.next()).?;
    defer event.deinit();
    try t.expectEqualSlices(u8, "clipboard", event.agent_message.data.bytes());
    var token: s.agent.SendToken = .{};
    try t.expect(try main.sender.send(1, 8, 0, "host", &token));
    main.deinit();
    try t.expectEqualSlices(u8, "clipboard", event.agent_message.data.bytes());
    var framer: s.framer.Framer = .{ .allocator = a, .mode = .mini };
    defer framer.deinit();
    try framer.append(fake.output.bytes.items);
    const expected = [_]u16{ 105, 106, 104, 1, 3, 2, 2, 2, 108, 2, 108, 2, 2, 107 };
    for (expected) |kind| {
        const message = (try framer.nextMessage()).?;
        defer message.deinit();
        try t.expectEqual(kind, message.kind);
        if (kind == 3) try t.expectEqual(@as(usize, 12), message.body.bytes().len);
    }
    try t.expect((try framer.nextMessage()) == null);
}
test "Main rejects before init, bootstrap migration and disconnected Agent data" {
    for ([_]u8{ 0, 1, 2 }) |mode| {
        var input: s.bytes.Writer = .{ .allocator = a, .limit = 1024 };
        defer input.deinit();
        if (mode != 0) try initMessage(&input, false, 0);
        if (mode == 0) try helpers.frame(&input, null, 4, &.{}) else if (mode == 1) try helpers.frame(&input, null, 102, &.{}) else try helpers.frame(&input, null, 109, &.{1});
        const barrier = try s.barrier.Barrier.create(a);
        defer barrier.destroy();
        var fake: helpers.Fake = .{ .input = input.bytes.items };
        defer fake.output.deinit();
        var channel = s.channel.Channel.init(a, main_key, fake.io(), .mini, barrier);
        defer channel.deinit();
        var clock: Clock = .{};
        var main = s.main_channel.Main.init(a, &channel, clock.adapter());
        defer main.deinit();
        try t.expectError(switch (mode) {
            0 => error.ExpectedMainInit,
            1 => error.UnexpectedMigration,
            else => error.InvalidAgentState,
        }, main.bootstrap());
        try t.expect(fake.cancelled);
    }
}
test "Main preserves channel migration data without cancelling source and negotiates seamless ACK/NACK" {
    for ([_]u16{ 117, 118, 1 }) |kind| {
        var input: s.bytes.Writer = .{ .allocator = a, .limit = 1024 };
        defer input.deinit();
        try helpers.frame(&input, null, kind, if (kind == 1) &.{ 2, 0, 0, 0 } else &.{});
        if (kind == 1) try helpers.frame(&input, null, 2, "migration");
        const barrier = try s.barrier.Barrier.create(a);
        defer barrier.destroy();
        var fake: helpers.Fake = .{ .input = input.bytes.items };
        defer fake.output.deinit();
        var channel = s.channel.Channel.init(a, main_key, fake.io(), .mini, barrier);
        defer channel.deinit();
        var clock: Clock = .{};
        var main = s.main_channel.Main.init(a, &channel, clock.adapter());
        defer main.deinit();
        if (kind != 1) try t.expectEqual(kind == 117, try main.negotiateSeamless(2)) else {
            try t.expectError(error.MigrationRequested, main.bootstrap());
            try t.expect(!fake.cancelled);
            const data = (try main.takeMigration()).?;
            defer data.release();
            try t.expectEqualSlices(u8, "migration", data.bytes());
        }
    }
}
test "Agent assembly every split, multiple messages, bounds and retained ownership" {
    var bytes: s.bytes.Writer = .{ .allocator = a, .limit = 1024 };
    defer bytes.deinit();
    try agentBytes(&bytes, 4, "123456789");
    try agentBytes(&bytes, 5, "");
    for (0..bytes.bytes.items.len + 1) |split| {
        var decoder: s.agent.Decoder = .{ .allocator = a };
        defer decoder.deinit();
        const first = try decoder.append(bytes.bytes.items[0..split]);
        defer first.deinit();
        const second = try decoder.append(bytes.bytes.items[split..]);
        defer second.deinit();
        try t.expectEqual(@as(usize, 2), first.items.len + second.items.len);
        decoder.reset();
        const message = if (first.items.len > 0) first.items[0] else second.items[0];
        try t.expectEqualSlices(u8, "123456789", message.data.bytes());
    }
    var decoder: s.agent.Decoder = .{ .allocator = a, .limits = .{ .packet = 4, .data = 16 } };
    defer decoder.deinit();
    try t.expectError(error.MessageTooLarge, decoder.append("12345"));
}
const Gate = struct {
    mutex: s.sync.Mutex = .{},
    changed: s.sync.Condition = .{},
    entered: bool = false,
    released: bool = false,
    cancelled: bool = false,
    fail_on: usize = 0,
    calls: usize = 0,
    output: s.bytes.Writer = .{ .allocator = a, .limit = 65536 },
    fn deinit(self: *Gate) void {
        self.output.deinit();
        self.changed.deinit();
        self.mutex.deinit();
    }
    fn read(_: *anyopaque, _: []u8) !usize {
        return error.ConnectionClosed;
    }
    fn write(ctx: *anyopaque, bytes: []const u8) !void {
        const self: *Gate = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.calls += 1;
        if (self.fail_on == self.calls) return error.ConnectionFailed;
        try self.output.append(bytes);
        if (self.calls == 1) {
            self.entered = true;
            self.changed.broadcast();
            while (!self.released and !self.cancelled) self.changed.wait(&self.mutex);
        }
        if (self.cancelled) return error.Cancelled;
    }
    fn cancel(ctx: *anyopaque) void {
        const self: *Gate = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cancelled = true;
        self.changed.broadcast();
    }
    fn io(self: *Gate) s.channel.IO {
        return .{ .context = self, .read_fn = read, .write_fn = write, .cancel_fn = cancel };
    }
    fn wait(self: *Gate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.entered) self.changed.wait(&self.mutex);
    }
    fn release(self: *Gate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.released = true;
        self.changed.broadcast();
    }
};
const Producer = struct {
    sender: *s.agent.Sender,
    data: []const u8,
    kind: u32 = 4,
    token: s.agent.SendToken = .{},
    result: ?anyerror = null,
    sent: bool = false,
    fn run(self: *Producer) void {
        self.sent = self.sender.send(1, self.kind, 0, self.data, &self.token) catch |err| {
            self.result = err;
            return;
        };
    }
};
test "Agent whole message token reservation and fragment serialization across concurrent producers" {
    const b = try s.barrier.Barrier.create(a);
    defer b.destroy();
    var gate: Gate = .{};
    defer gate.deinit();
    var channel = s.channel.Channel.init(a, main_key, gate.io(), .mini, b);
    defer channel.deinit();
    var sender: s.agent.Sender = .{ .allocator = a, .connection = &channel };
    defer sender.deinit();
    try sender.start(4);
    const payload: [2500]u8 = @splat(0x77);
    var one: Producer = .{ .sender = &sender, .data = &payload, .kind = 4 };
    var two: Producer = .{ .sender = &sender, .data = &payload, .kind = 5 };
    const thread1 = try std.Thread.spawn(.{}, Producer.run, .{&one});
    gate.wait();
    const thread2 = try std.Thread.spawn(.{}, Producer.run, .{&two});
    gate.release();
    thread1.join();
    thread2.join();
    try t.expect(one.sent and two.sent and one.result == null and two.result == null);
    var token: s.agent.SendToken = .{};
    try t.expect(!try sender.send(1, 6, 0, "", &token));
    var frames: s.framer.Framer = .{ .allocator = a, .mode = .mini };
    defer frames.deinit();
    try frames.append(gate.output.bytes.items);
    var decoder: s.agent.Decoder = .{ .allocator = a };
    defer decoder.deinit();
    var count: usize = 0;
    while (try frames.nextMessage()) |frame| {
        defer frame.deinit();
        try t.expectEqual(@as(u16, 107), frame.kind);
        const messages = try decoder.append(frame.body.bytes());
        defer messages.deinit();
        for (messages.items) |message| {
            try t.expectEqual(@as(u32, 4) + @as(u32, @intCast(count)), message.kind);
            try t.expectEqualSlices(u8, &payload, message.data.bytes());
            count += 1;
        }
    }
    try t.expectEqual(@as(usize, 2), count);
}
test "Agent prefix failure closes stream; reset does not restore old tokens; active cancellation unblocks" {
    for (0..3) |mode| {
        const b = try s.barrier.Barrier.create(a);
        defer b.destroy();
        var gate: Gate = .{ .fail_on = if (mode == 0) 2 else 0 };
        defer gate.deinit();
        var channel = s.channel.Channel.init(a, main_key, gate.io(), .mini, b);
        defer channel.deinit();
        var sender: s.agent.Sender = .{ .allocator = a, .connection = &channel };
        defer sender.deinit();
        try sender.start(2);
        const payload: [2500]u8 = @splat(1);
        var producer: Producer = .{ .sender = &sender, .data = &payload };
        const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
        gate.wait();
        if (mode == 1) {
            sender.reset();
            try sender.start(0);
        } else if (mode == 2) sender.cancelSend(&producer.token);
        gate.release();
        thread.join();
        try t.expect(producer.result != null);
        if (mode == 0) try t.expect(gate.cancelled);
        if (mode == 1) {
            var token: s.agent.SendToken = .{};
            try t.expect(!try sender.send(1, 4, 0, "", &token));
        }
    }
}
test "Agent active fragments stay on retired connection; new sends use rebound connection" {
    const b = try s.barrier.Barrier.create(a);
    defer b.destroy();
    var gate: Gate = .{};
    defer gate.deinit();
    var replacement: Gate = .{ .released = true };
    defer replacement.deinit();
    var old = s.channel.Channel.init(a, main_key, gate.io(), .mini, b);
    defer old.deinit();
    var new = s.channel.Channel.init(a, main_key, replacement.io(), .mini, b);
    defer new.deinit();
    var sender: s.agent.Sender = .{ .allocator = a, .connection = &old };
    defer sender.deinit();
    try sender.start(3);
    const payload: [2500]u8 = @splat(1);
    var producer: Producer = .{ .sender = &sender, .data = &payload };
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
    gate.wait();
    try t.expect((try sender.rebind(&new)) == &old);
    gate.release();
    thread.join();
    try t.expect(producer.sent);
    try sender.waitRetired(&old);
    try t.expectEqual(@as(usize, 2), gate.calls);
    var token: s.agent.SendToken = .{};
    try t.expect(try sender.send(1, 5, 0, "next", &token));
    try t.expectEqual(@as(usize, 1), replacement.calls);
}
fn allocationRun(allocator: std.mem.Allocator) !void {
    var decoder: s.agent.Decoder = .{ .allocator = allocator };
    defer decoder.deinit();
    var bytes: s.bytes.Writer = .{ .allocator = a, .limit = 1024 };
    defer bytes.deinit();
    try agentBytes(&bytes, 4, "hello");
    const first = try decoder.append(bytes.bytes.items[0..7]);
    defer first.deinit();
    const second = try decoder.append(bytes.bytes.items[7..]);
    defer second.deinit();
}
test "Agent assembly allocation failures release partial stream and decoded messages" {
    try t.checkAllAllocationFailures(a, allocationRun, .{});
}

const ClockWait = struct {
    clock: *s.clock.Clock,
    token: s.clock.Token = .{},
    target: u32,
    result: ?anyerror = null,
    delay: ?i32 = null,
    fn run(self: *ClockWait) void {
        self.delay = self.clock.wait(self.target, &self.token) catch |err| {
            self.result = err;
            return;
        };
    }
};
test "continuous multimedia clock signed wrap, playback delay, reset wake and cancellation" {
    try t.expectEqual(@as(i32, 10), s.clock.margin(0xfffffff8, 2));
    try t.expectEqual(@as(i32, -10), s.clock.margin(2, 0xfffffff8));
    for (0..2) |mode| {
        var clock = try s.clock.Clock.init();
        defer clock.deinit();
        clock.reset(100);
        var waiter: ClockWait = .{ .clock = &clock, .target = 500000 };
        const thread = try std.Thread.spawn(.{}, ClockWait.run, .{&waiter});
        if (mode == 0) clock.reset(500001) else clock.cancelWait(&waiter.token);
        thread.join();
        if (mode == 0) try t.expect(waiter.delay.? <= 0) else try t.expectEqual(error.Cancelled, waiter.result.?);
        clock.synchronize(10, 20);
        try t.expectEqual(@as(?u32, 20), clock.playbackDelay());
        clock.stopPlayback();
        try t.expect(clock.playbackDelay() == null);
    }
}

fn mainAllocationRun(allocator: std.mem.Allocator) !void {
    var input: s.bytes.Writer = .{ .allocator = a, .limit = 4096 };
    defer input.deinit();
    try initMessage(&input, true, 3);
    var agent_wire: s.bytes.Writer = .{ .allocator = a, .limit = 1024 };
    defer agent_wire.deinit();
    try agentBytes(&agent_wire, 4, "fixture");
    try helpers.frame(&input, null, 109, agent_wire.bytes.items);
    try listMessage(&input);
    const barrier = try s.barrier.Barrier.create(a);
    defer barrier.destroy();
    var fake: helpers.Fake = .{ .input = input.bytes.items };
    defer fake.output.deinit();
    var channel = s.channel.Channel.init(allocator, main_key, fake.io(), .mini, barrier);
    defer channel.deinit();
    var clock: Clock = .{};
    var main = s.main_channel.Main.init(allocator, &channel, clock.adapter());
    defer main.deinit();
    const info = try main.bootstrap();
    defer info.deinit();
    const event = (try main.next()).?;
    defer event.deinit();
    var token: s.agent.SendToken = .{};
    try t.expect(try main.sender.send(1, 4, 0, "host", &token));
}
test "Main all allocation failures clean bootstrap queue Agent fragments and retained deliveries" {
    try t.checkAllAllocationFailures(a, mainAllocationRun, .{});
}
test "Main limits queued Agent events and rejects duplicate lifecycle transitions" {
    for (0..3) |mode| {
        var input: s.bytes.Writer = .{ .allocator = a, .limit = 65536 };
        defer input.deinit();
        try initMessage(&input, mode != 2, 0);
        if (mode == 0) {
            var bytes: s.bytes.Writer = .{ .allocator = a, .limit = 2048 };
            defer bytes.deinit();
            for (0..65) |_| try agentBytes(&bytes, 4, "");
            try helpers.frame(&input, null, 109, bytes.bytes.items);
        } else if (mode == 1) try helpers.frame(&input, null, 107, &.{}) else try helpers.frame(&input, null, 108, &.{ 0, 0, 0, 0 });
        const b = try s.barrier.Barrier.create(a);
        defer b.destroy();
        var fake: helpers.Fake = .{ .input = input.bytes.items };
        defer fake.output.deinit();
        var channel = s.channel.Channel.init(a, main_key, fake.io(), .mini, b);
        defer channel.deinit();
        var clock: Clock = .{};
        var main = s.main_channel.Main.init(a, &channel, clock.adapter());
        defer main.deinit();
        try t.expectError(if (mode == 0) error.MessageTooLarge else error.InvalidAgentState, main.bootstrap());
        try t.expect(fake.cancelled);
    }
}
test "migration exact string parsing bounds truncation UTF8 ports and seamless version" {
    var bytes: s.bytes.Writer = .{ .allocator = a, .limit = 8192 };
    defer bytes.deinit();
    try bytes.write(u16, 5900);
    try bytes.write(u16, 5901);
    try bytes.write(u32, 5);
    try bytes.append("host\x00");
    try bytes.write(u32, 0);
    try bytes.write(u32, 2);
    const command = (try s.migration.decode(116, bytes.bytes.items)).?;
    try t.expectEqualSlices(u8, "host", command.begin_seamless.destination.host);
    try t.expectEqual(@as(u32, 2), command.begin_seamless.source_version);
    for (0..bytes.bytes.items.len) |size| {
        if (s.migration.decode(116, bytes.bytes.items[0..size])) |_| return error.UnexpectedSuccess else |_| {}
    }
    try t.expectError(error.InvalidPort, s.migration.decode(101, &.{ 0, 0, 0, 0 }));
    try t.expectError(error.MessageTooLarge, s.migration.decode(101, &.{ 1, 0, 0, 0, 1, 16, 0, 0 }));
    try t.expectError(error.InvalidString, s.migration.decode(101, &.{ 1, 0, 0, 0, 2, 0, 0, 0, 255, 0 }));
    try t.expectError(error.InvalidString, s.migration.decode(101, &.{ 1, 0, 0, 0, 3, 0, 0, 0, 'a', 0, 0 }));
    for ([_]u16{ 102, 112, 117, 118 }) |kind| {
        try t.expect((try s.migration.decode(kind, &.{})) != null);
        try t.expectError(error.TrailingBytes, s.migration.decode(kind, &.{0}));
    }
}

test "Agent epochs fence old replies after same-session disconnect and reconnect without token consumption" {
    var input: s.bytes.Writer = .{ .allocator = a, .limit = 4096 };
    defer input.deinit();
    try initMessage(&input, true, 4);
    try listMessage(&input);
    var payload: s.bytes.Writer = .{ .allocator = a, .limit = 256 };
    defer payload.deinit();
    try agentBytes(&payload, 4, "epoch fixture");
    try helpers.frame(&input, null, 109, payload.bytes.items);
    try helpers.frame(&input, null, 108, &.{ 0, 0, 0, 0 });
    try helpers.frame(&input, null, 115, &.{ 4, 0, 0, 0 });
    try helpers.frame(&input, null, 109, payload.bytes.items);
    const barrier = try s.barrier.Barrier.create(a);
    defer barrier.destroy();
    var fake: helpers.Fake = .{ .input = input.bytes.items };
    defer fake.output.deinit();
    var channel = s.channel.Channel.init(a, main_key, fake.io(), .mini, barrier);
    defer channel.deinit();
    var clock: Clock = .{};
    var main = s.main_channel.Main.init(a, &channel, clock.adapter());
    defer main.deinit();
    const boot = try main.bootstrap();
    defer boot.deinit();
    const old = (try main.next()).?;
    defer old.deinit();
    try t.expectEqual(boot.agent_epoch, old.agent_message.epoch);
    const disconnected = (try main.next()).?;
    defer disconnected.deinit();
    const connected = (try main.next()).?;
    defer connected.deinit();
    try t.expect(connected.agent_connected > disconnected.agent_disconnected.epoch and disconnected.agent_disconnected.epoch > boot.agent_epoch);
    const before = fake.output.bytes.items.len;
    const tokens = main.sender.tokens;
    var token: s.agent.SendToken = .{};
    try t.expectError(error.StaleAgentGeneration, main.sender.sendAt(boot.agent_epoch, 1, 4, 0, "old", &token));
    try t.expectEqual(before, fake.output.bytes.items.len);
    try t.expectEqual(tokens, main.sender.tokens);
    try t.expect(try main.sender.sendAt(connected.agent_connected, 1, 4, 0, "current", &token));
    const fresh = (try main.next()).?;
    defer fresh.deinit();
    try t.expectEqual(connected.agent_connected, fresh.agent_message.epoch);
}
