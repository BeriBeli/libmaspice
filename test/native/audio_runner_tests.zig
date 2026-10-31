const std = @import("std");
const t = std.testing;
const a = t.allocator;
const s = @import("spice");
const audio = s.audio;
const sync = s.sync;
const cancel = s.cancel;
const wire = s.audio_wire;
extern "c" fn usleep(c_uint) c_int;
const Runtime = struct {
    pub const Event = struct {
        lifecycle: u64 = 1,
        key: struct { id: u8 = 0 } = .{},
        value: union(enum) { connected, disconnected, failed: anyerror, migration, child: union(enum) { playback: audio.Event, record: audio.Event, other }, other },
        pub fn weight(self: Event) usize {
            return switch (self.value) {
                .child => |v| switch (v) {
                    .playback, .record => |x| x.weight(),
                    else => 0,
                },
                else => 0,
            };
        }
        pub fn deinit(self: Event) void {
            switch (self.value) {
                .child => |v| switch (v) {
                    .playback, .record => |x| x.deinit(),
                    else => {},
                },
                else => {},
            }
        }
    };
    mutex: sync.Mutex = .{},
    changed: sync.Condition = .{},
    epoch: u64 = 1,
    lifecycle: u64 = 1,
    blocked: bool = false,
    entered: bool = false,
    marked: usize = 0,
    packets: usize = 0,
    bytes: [128]u8 = undefined,
    size: usize = 0,
    delays: std.atomic.Value(usize) = .init(0),
    fn deinit(self: *Runtime) void {
        self.changed.deinit();
        self.mutex.deinit();
    }
    fn wake(raw: *anyopaque) void {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        self.changed.broadcast();
        self.mutex.unlock();
    }
    pub fn sendRecordAt(self: *Runtime, _: u8, lifecycle: u64, epoch: u64, input: audio.RecordInput, token: *cancel.Token) !void {
        var registration: cancel.Registration = .{ .context = self, .wake = wake };
        token.register(&registration);
        defer token.unregister(&registration);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.entered = true;
        self.changed.broadcast();
        while (self.blocked) {
            try token.check();
            self.changed.wait(&self.mutex);
        }
        try token.check();
        if (epoch != self.epoch or lifecycle != self.lifecycle) return error.AudioStreamChanged;
        switch (input) {
            .begin => self.marked += 1,
            .packet => |v| {
                if (v.bytes.len > self.bytes.len) return error.TestPacketLarge;
                @memcpy(self.bytes[0..v.bytes.len], v.bytes);
                self.size = v.bytes.len;
                self.packets += 1;
            },
        }
    }
    pub fn reportPlaybackDelay(self: *Runtime, _: u8, _: u32) !void {
        _ = self.delays.fetchAdd(1, .acq_rel);
    }
    fn waitEntered(self: *Runtime) !void {
        for (0..3000) |_| {
            self.mutex.lock();
            const value = self.entered;
            self.mutex.unlock();
            if (value) return;
            _ = usleep(1000);
        }
        return error.Timeout;
    }
};
const Devices = struct {
    state: *State,
    const State = struct {
        mutex: sync.Mutex = .{},
        playback: ?*Playback = null,
        capture: ?*Capture = null,
        created: usize = 0,
        destroyed: usize = 0,
        fn deinit(self: *State) void {
            std.debug.assert(self.playback == null and self.capture == null);
            self.mutex.deinit();
        }
        fn push(self: *State, bytes: []const u8) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            const device = self.capture orelse return error.NoCapture;
            _ = device.converter.queue.queue.enqueue(99, bytes);
        }
        fn render(self: *State, bytes: []u8) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            const device = self.playback orelse return error.NoPlayback;
            _ = device.playback.render(bytes);
        }
    };
    pub const Playback = struct {
        allocator: std.mem.Allocator,
        state: *State,
        playback: s.audio_buffer.Playback,
        gain: f32 = 1,
        pub fn start(_: *Playback) !void {}
        pub fn setGain(self: *Playback, muted: bool, volume: []const u16) void {
            self.gain = if (muted) 0 else if (volume.len > 0) @as(f32, @floatFromInt(volume[0])) / 65535 else 1;
        }
        pub fn destroy(self: *Playback) void {
            self.state.mutex.lock();
            self.state.playback = null;
            self.state.destroyed += 1;
            self.state.mutex.unlock();
            self.playback.deinit();
            self.allocator.destroy(self);
        }
    };
    pub const Capture = struct {
        allocator: std.mem.Allocator,
        state: *State,
        converter: struct { queue: s.audio_buffer.Capture },
        pub fn start(_: *Capture) !void {}
        pub fn destroy(self: *Capture) void {
            self.state.mutex.lock();
            self.state.capture = null;
            self.state.destroyed += 1;
            self.state.mutex.unlock();
            self.converter.queue.deinit();
            self.allocator.destroy(self);
        }
    };
    pub fn playback(self: Devices, allocator: std.mem.Allocator, config: wire.Configuration, max: u32, min: u32) !*Playback {
        const value = try allocator.create(Playback);
        errdefer allocator.destroy(value);
        value.* = .{ .allocator = allocator, .state = self.state, .playback = try s.audio_buffer.Playback.init(allocator, try s.audio_ring.Capacity.pcm(config.frequency, config.channels, max), config.channels * 2, config.frequency, min) };
        self.state.mutex.lock();
        self.state.playback = value;
        self.state.created += 1;
        self.state.mutex.unlock();
        return value;
    }
    pub fn capture(self: Devices, allocator: std.mem.Allocator, config: wire.Configuration, max: u32) !*Capture {
        const value = try allocator.create(Capture);
        errdefer allocator.destroy(value);
        value.* = .{ .allocator = allocator, .state = self.state, .converter = .{ .queue = try s.audio_buffer.Capture.init(allocator, try s.audio_ring.Capacity.pcm(config.frequency, config.channels, max)) } };
        self.state.mutex.lock();
        self.state.capture = value;
        self.state.created += 1;
        self.state.mutex.unlock();
        return value;
    }
};
const Runner = s.audio_runner.Runner(Runtime, Devices);
fn observe(runner: *Runner, recording: bool, value: audio.Event) !void {
    try runner.observe(.{ .value = .{ .child = if (recording) .{ .record = value } else .{ .playback = value } } });
}
fn next(runner: *Runner, kind: @FieldType(s.audio_runner.Output, "kind")) !s.audio_runner.Output {
    for (0..3000) |_| {
        while (runner.next()) |out| {
            if (out.kind == kind) return out;
        }
        _ = usleep(1000);
    }
    return error.Timeout;
}
fn start(runner: *Runner, recording: bool, epoch: u64) !void {
    try observe(runner, recording, .{ .start = .{ .configuration = .{ .frequency = 8000, .channels = 1 }, .epoch = epoch } });
    _ = try next(runner, .started);
}
fn packet(runner: *Runner, bytes: []const u8) !void {
    const slice = try s.bytes.Slice.copy(a, bytes);
    defer slice.release();
    try observe(runner, false, .{ .packet = .{ .time = 1, .data = slice } });
}
fn waitPackets(runner: *Runner, n: u64) !void {
    for (0..3000) |_| {
        if (runner.statistics().scheduled_packets >= n) return;
        _ = usleep(1000);
    }
    return error.Timeout;
}
test "audio executor defaults do not open devices and playback policy runs without Swift scheduling" {
    var runtime: Runtime = .{};
    defer runtime.deinit();
    var state: Devices.State = .{};
    defer state.deinit();
    const off = try Runner.create(a, &runtime, .{ .state = &state }, .{});
    try observe(off, false, .{ .start = .{ .configuration = .{ .channels = 1, .frequency = 8000 } } });
    try observe(off, true, .{ .start = .{ .configuration = .{ .channels = 1, .frequency = 8000 }, .epoch = 1 } });
    off.destroy();
    try t.expectEqual(@as(usize, 0), state.created);
    const runner = try Runner.create(a, &runtime, .{ .state = &state }, .{ .playback = true, .maximum_queued_ms = 1, .delay_interval_ms = 1 });
    defer runner.destroy();
    try start(runner, false, 0);
    try packet(runner, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try waitPackets(runner, 1);
    var out: [4]u8 = undefined;
    try state.render(&out);
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &out);
    try packet(runner, &.{ 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24 });
    const overflow = try next(runner, .overflow);
    try t.expectEqual(@as(u32, 1), overflow.milliseconds);
    try t.expect(!overflow.recording);
    try observe(runner, false, .stop);
    _ = try next(runner, .stopped);
}
test "capture executor drains autonomously and old recording epochs cannot enter restarted streams" {
    var runtime: Runtime = .{};
    defer runtime.deinit();
    var state: Devices.State = .{};
    defer state.deinit();
    const runner = try Runner.create(a, &runtime, .{ .state = &state }, .{ .capture = true });
    defer runner.destroy();
    try start(runner, true, 1);
    try state.push(&.{ 1, 2, 3, 4 });
    var delivered = false;
    for (0..3000) |_| {
        runtime.mutex.lock();
        delivered = runtime.packets == 1;
        const correct = runtime.size == 4 and std.mem.eql(u8, &.{ 1, 2, 3, 4 }, runtime.bytes[0..runtime.size]);
        runtime.mutex.unlock();
        if (delivered) try t.expect(correct);
        if (delivered) break;
        _ = usleep(1000);
    }
    try t.expect(delivered);
    try runner.observe(.{ .value = .migration });
    runtime.mutex.lock();
    runtime.epoch = 2;
    runtime.mutex.unlock();
    try state.push(&.{ 5, 6 });
    const failure = try next(runner, .failed);
    try t.expectEqual(error.AudioStreamChanged, failure.failure.?);
    _ = try next(runner, .stopped);
    try start(runner, true, 2);
    try t.expectEqual(@as(usize, 2), state.created);
    runtime.mutex.lock();
    runtime.lifecycle = 2;
    runtime.mutex.unlock();
    try runner.observe(.{ .lifecycle = 2, .value = .migration });
    _ = try next(runner, .stopped);
    // A late old-guest START must not reopen microphone access.
    try observe(runner, true, .{ .start = .{ .configuration = .{ .channels = 1, .frequency = 8000 }, .epoch = 2 } });
    runner.stop();
}
test "audio executor stop and bounded event queue cancel blocked record begin and join devices" {
    for ([_]bool{ false, true }) |overflow| {
        var runtime: Runtime = .{ .blocked = true };
        defer runtime.deinit();
        var state: Devices.State = .{};
        defer state.deinit();
        const runner = try Runner.create(a, &runtime, .{ .state = &state }, .{ .capture = true });
        var owned = true;
        defer if (owned) runner.destroy();
        try observe(runner, true, .{ .start = .{ .configuration = .{ .channels = 1, .frequency = 8000 }, .epoch = 1 } });
        try runtime.waitEntered();
        if (overflow) {
            for (0..64) |_| try observe(runner, true, .{ .mute = true });
            try t.expectError(error.AudioEventQueueFull, observe(runner, true, .{ .mute = false }));
        } else runner.stop();
        runner.destroy();
        owned = false;
        try t.expectEqual(state.created, state.destroyed);
    }
}
fn runnerFailures(allocator: std.mem.Allocator) !void {
    var runtime: Runtime = .{};
    defer runtime.deinit();
    var state: Devices.State = .{};
    defer state.deinit();
    const runner = try Runner.create(allocator, &runtime, .{ .state = &state }, .{});
    runner.destroy();
}
test "audio executor creation allocation failures leave no worker" {
    try t.checkAllAllocationFailures(a, runnerFailures, .{});
}

test "late audio attach replays retained PCM and detach joins observations across guest boundaries" {
    var runtime: Runtime = .{};
    defer runtime.deinit();
    var devices: Devices.State = .{};
    defer devices.deinit();
    var route: s.audio_route.Route(Runtime, Runner) = .{};
    defer route.deinit();
    try route.observe(.{ .value = .{ .child = .{ .playback = .{ .start = .{ .configuration = .{ .frequency = 8000, .channels = 1 }, .epoch = 1 } } } } });
    {
        const data = try s.bytes.Slice.copy(a, &.{ 1, 2, 3, 4 });
        defer data.release();
        try route.observe(.{ .value = .{ .child = .{ .playback = .{ .packet = .{ .time = 1, .data = data } } } } });
    }
    const runner = try Runner.create(a, &runtime, .{ .state = &devices }, .{ .playback = true });
    defer runner.destroy();
    try route.attach(false, runner);
    defer route.detach(false, runner);
    _ = try next(runner, .started);
    try waitPackets(runner, 1);
    try t.expectError(error.AudioAlreadyAttached, route.attach(false, runner));
    try route.observe(.{ .value = .disconnected });
    _ = try next(runner, .stopped);
    route.detach(false, runner);
    try route.observe(.{ .value = .{ .child = .{ .playback = .{ .mute = true } } } });
    try route.observe(.{ .lifecycle = 2, .value = .connected });
    try route.observe(.{ .lifecycle = 2, .value = .{ .child = .{ .playback = .{ .mute = false } } } });
    try route.attach(false, runner);
    try t.expect(!(try next(runner, .mute)).muted);
    route.detach(false, runner);
    runner.join();
    try t.expectEqual(@as(u64, 1), runner.statistics().scheduled_packets);
    try t.expect(runner.status().finished);
}

test "unused audio replay cache is bounded without penalizing direct public consumers" {
    var route: s.audio_route.Route(Runtime, Runner) = .{};
    defer route.deinit();
    for (0..100) |_| try route.observe(.{ .value = .{ .child = .{ .record = .{ .mute = true } } } });
    try t.expectEqual(@as(usize, 32), route.slots[1].count);
    try route.observe(.{ .value = .disconnected });
    try t.expectEqual(@as(usize, 0), route.slots[1].count);
}

test "audio delay interval retains full public UInt32 range" {
    var runtime: Runtime = .{};
    defer runtime.deinit();
    var devices: Devices.State = .{};
    defer devices.deinit();
    const runner = try Runner.create(a, &runtime, .{ .state = &devices }, .{ .delay_interval_ms = std.math.maxInt(u32) });
    defer runner.destroy();
    runner.join();
    try t.expect(runner.status().finished);
}
