//! Optional native audio executor. Feed ordered Desktop observations before
//! destroying their owner. Hardware access requires explicit playback/capture
//! options; no device is opened until the matching START. Runtime is borrowed
//! until destroy. stop cancels pending record sends and destroy joins the worker
//! and native callbacks. Consumers drain bounded notification events with next.
const std = @import("std");
const sync = @import("sync.zig");
const cancellation = @import("cancel.zig");
const clock = @import("clock.zig");
const audio = @import("audio.zig");
const wire = @import("audio_wire.zig");
const buffers = @import("audio_buffer.zig");
const native = @import("audio_native.zig");
extern "c" fn pthread_cond_timedwait_relative_np(*std.c.pthread_cond_t, *std.c.pthread_mutex_t, *const std.c.timespec) std.c.E;
extern "c" fn mach_absolute_time() u64;
pub const NativeDevices = struct {
    pub const Playback = native.PlaybackDevice;
    pub const Capture = native.CaptureDevice;
    pub fn playback(_: NativeDevices, a: std.mem.Allocator, c: wire.Configuration, max_ms: u32, min_ms: u32) !*Playback {
        return Playback.create(a, c.frequency, c.channels, max_ms, min_ms);
    }
    pub fn capture(_: NativeDevices, a: std.mem.Allocator, c: wire.Configuration, max_ms: u32) !*Capture {
        return Capture.create(a, c.frequency, c.channels, max_ms);
    }
};
pub const Options = struct { playback: bool = false, capture: bool = false, playback_id: u8 = 0, record_id: u8 = 0, maximum_queued_ms: u32 = 500, delay_interval_ms: u32 = 50, maximum_event_bytes: usize = 32 * 1024 * 1024 };
pub const Output = struct {
    kind: enum { started, stopped, mute, volume, overflow, oversized, underrun, failed },
    recording: bool,
    configuration: wire.Configuration = .{ .channels = 0, .frequency = 0 },
    milliseconds: u32 = 0,
    muted: bool = false,
    volume: wire.Volume = .{ .count = 0 },
    count: u64 = 0,
    failure: ?anyerror = null,
};
pub const Statistics = struct { scheduled_packets: u64 = 0, scheduled_frames: u64 = 0, queued_playback_bytes: usize = 0, queued_capture_bytes: usize = 0, underflows: u64 = 0, notifications_dropped: u64 = 0 };
pub fn Runner(comptime Runtime: type, comptime Devices: type) type {
    return struct {
        const Self = @This();
        const Command = struct {
            lifecycle: u64,
            value: union(enum) { identity, disconnected, playback: audio.Event, record: audio.Event },
            fn deinit(self: Command) void {
                switch (self.value) {
                    .playback, .record => |v| v.deinit(),
                    else => {},
                }
            }
            fn weight(self: Command) usize {
                return switch (self.value) {
                    .playback, .record => |v| v.weight(),
                    else => 0,
                };
            }
        };
        allocator: std.mem.Allocator,
        runtime: *Runtime,
        devices: Devices,
        options: Options,
        timebase: std.c.mach_timebase_info_data,
        mutex: sync.Mutex = .{},
        changed: sync.Condition = .{},
        thread: ?std.Thread = null,
        stopping: bool = false,
        finished: bool = false,
        failure: ?anyerror = null,
        token: cancellation.Token = .{},
        commands: [64]Command = undefined,
        head: usize = 0,
        count: usize = 0,
        queued_bytes: usize = 0,
        outputs: [32]Output = undefined,
        out_head: usize = 0,
        out_count: usize = 0,
        stats: Statistics = .{},
        // Everything below is worker-owned; snapshots above are copied under mutex.
        lifecycle: u64 = 0,
        playback: ?*Devices.Playback = null,
        capture: ?*Devices.Capture = null,
        playback_configuration: ?wire.Configuration = null,
        record_configuration: ?wire.Configuration = null,
        record_epoch: u64 = 0,
        volume: wire.Volume = .{ .count = 0 },
        muted: bool = false,
        minimum_ms: u32 = 0,
        reported_underflows: u64 = 0,
        pub fn create(a: std.mem.Allocator, runtime: *Runtime, devices: Devices, options: Options) !*Self {
            if (options.maximum_queued_ms == 0 or options.delay_interval_ms == 0 or options.maximum_event_bytes > 64 * 1024 * 1024) return error.InvalidLimits;
            // Every positive UInt32 interval fits safely when converted to
            // nanoseconds; the public Swift API also accepts the full range.
            var timebase: std.c.mach_timebase_info_data = undefined;
            if (std.c.mach_timebase_info(&timebase) != 0 or timebase.denom == 0) return error.ClockUnavailable;
            const self = try a.create(Self);
            self.* = .{ .allocator = a, .runtime = runtime, .devices = devices, .options = options, .timebase = timebase };
            errdefer {
                self.token.deinit();
                self.changed.deinit();
                self.mutex.deinit();
                a.destroy(self);
            }
            self.thread = try std.Thread.spawn(.{}, run, .{self});
            return self;
        }
        pub fn stop(self: *Self) void {
            self.mutex.lock();
            self.stopping = true;
            self.changed.broadcast();
            self.mutex.unlock();
            self.token.cancel();
        }
        // Join is an owner operation: no concurrent join/destroy callers.
        // Status/statistics/next remain usable after the worker has ended.
        pub fn join(self: *Self) void {
            self.stop();
            if (self.thread) |thread| thread.join();
            self.thread = null;
        }
        pub fn destroy(self: *Self) void {
            self.join();
            for (0..self.count) |i| self.commands[(self.head + i) % self.commands.len].deinit();
            self.token.deinit();
            self.changed.deinit();
            self.mutex.deinit();
            self.allocator.destroy(self);
        }
        pub fn status(self: *Self) struct { finished: bool, failure: ?anyerror } {
            self.mutex.lock();
            defer self.mutex.unlock();
            return .{ .finished = self.finished, .failure = self.failure };
        }
        pub fn statistics(self: *Self) Statistics {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.stats;
        }
        pub fn next(self: *Self) ?Output {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.out_count == 0) return null;
            const value = self.outputs[self.out_head];
            self.out_head = (self.out_head + 1) % self.outputs.len;
            self.out_count -= 1;
            return value;
        }
        fn output(self: *Self, value: Output) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            // Matches the public Swift sinks' bufferingNewest(32) notification policy.
            if (self.out_count == self.outputs.len) {
                self.out_head = (self.out_head + 1) % self.outputs.len;
                self.out_count -= 1;
                self.stats.notifications_dropped +|= 1;
            }
            self.outputs[(self.out_head + self.out_count) % self.outputs.len] = value;
            self.out_count += 1;
        }
        pub fn observe(self: *Self, event: Runtime.Event) !void {
            var command: Command = .{ .lifecycle = event.lifecycle, .value = .identity };
            switch (event.value) {
                .connected, .migration => {},
                .disconnected, .failed => command.value = .disconnected,
                .child => |child| switch (child) {
                    .playback => |value| {
                        if (!self.options.playback or event.key.id != self.options.playback_id) return;
                        command.value = .{ .playback = value };
                    },
                    .record => |value| {
                        if (!self.options.capture or event.key.id != self.options.record_id) return;
                        command.value = .{ .record = value };
                    },
                    else => return,
                },
                else => return,
            }
            switch (command.value) {
                .playback => |*v| {
                    if (v.* == .packet) v.packet.data = v.packet.data.clone();
                },
                .record => |*v| {
                    if (v.* == .packet) v.packet.data = v.packet.data.clone();
                },
                else => {},
            }
            errdefer command.deinit();
            const weight = command.weight();
            self.mutex.lock();
            var locked = true;
            defer if (locked) self.mutex.unlock();
            if (self.stopping) return error.Cancelled;
            if (self.count == self.commands.len or weight > self.options.maximum_event_bytes - self.queued_bytes) {
                self.failure = error.AudioEventQueueFull;
                self.stopping = true;
                self.changed.broadcast();
                self.mutex.unlock();
                locked = false;
                self.token.cancel();
                return error.AudioEventQueueFull;
            }
            self.commands[(self.head + self.count) % self.commands.len] = command;
            self.count += 1;
            self.queued_bytes += weight;
            self.changed.broadcast();
        }
        fn stopPlayback(self: *Self, emit: bool) void {
            if (self.playback) |device| device.destroy();
            self.playback = null;
            self.playback_configuration = null;
            if (emit) self.output(.{ .kind = .stopped, .recording = false });
        }
        fn stopCapture(self: *Self, emit: bool) void {
            if (self.capture) |device| device.destroy();
            self.capture = null;
            self.record_configuration = null;
            self.record_epoch = 0;
            if (emit) self.output(.{ .kind = .stopped, .recording = true });
        }
        fn fail(self: *Self, recording: bool, err: anyerror) void {
            self.output(.{ .kind = .failed, .recording = recording, .failure = err });
            if (recording) self.stopCapture(self.capture != null) else self.stopPlayback(self.playback != null);
        }
        fn handle(self: *Self, command: Command) void {
            if (command.lifecycle < self.lifecycle) return;
            if (command.lifecycle != self.lifecycle) {
                self.stopPlayback(self.playback != null);
                self.stopCapture(self.capture != null);
                self.lifecycle = command.lifecycle;
                self.volume = .{ .count = 0 };
                self.muted = false;
                self.minimum_ms = 0;
            }
            switch (command.value) {
                .identity => {},
                .disconnected => {
                    self.stopPlayback(self.playback != null);
                    self.stopCapture(self.capture != null);
                },
                .playback => |value| self.playbackEvent(value) catch |err| self.fail(false, err),
                .record => |value| self.recordEvent(value) catch |err| self.fail(true, err),
            }
        }
        fn playbackEvent(self: *Self, value: audio.Event) !void {
            switch (value) {
                .mode => {},
                .start => |v| {
                    try wire.validate(v.configuration);
                    self.stopPlayback(self.playback != null);
                    const device = try self.devices.playback(self.allocator, v.configuration, self.options.maximum_queued_ms, self.minimum_ms);
                    errdefer device.destroy();
                    try device.start();
                    device.setGain(self.muted, self.volume.values[0..self.volume.count]);
                    self.playback = device;
                    self.playback_configuration = v.configuration;
                    self.reported_underflows = 0;
                    self.mutex.lock();
                    self.stats.scheduled_packets = 0;
                    self.stats.scheduled_frames = 0;
                    self.mutex.unlock();
                    self.output(.{ .kind = .started, .recording = false, .configuration = v.configuration });
                },
                .packet => |v| {
                    const device = self.playback orelse return error.AudioStopped;
                    const config = self.playback_configuration.?;
                    try wire.validatePCM(config, v.data.bytes());
                    const frame_bytes = config.channels * 2;
                    const result = device.playback.enqueue(v.time, v.data.bytes());
                    switch (result) {
                        .enqueued => |info| {
                            if (info.dropped_packets > 0 or info.dropped_bytes > 0) self.output(.{ .kind = .overflow, .recording = false, .milliseconds = buffers.milliseconds(info.dropped_bytes / frame_bytes, config.frequency) });
                            self.mutex.lock();
                            self.stats.scheduled_packets +%= 1;
                            self.stats.scheduled_frames +%= v.data.bytes().len / frame_bytes;
                            self.mutex.unlock();
                        },
                        .oversized, .lease_conflict => |size| self.output(.{ .kind = .oversized, .recording = false, .milliseconds = buffers.milliseconds(size / frame_bytes, config.frequency) }),
                        .closed => return error.AudioStopped,
                    }
                    self.reportUnderflows();
                },
                .stop => self.stopPlayback(true),
                .volume => |v| {
                    self.volume = v;
                    if (self.playback) |device| device.setGain(self.muted, v.values[0..v.count]);
                },
                .mute => |v| {
                    self.muted = v;
                    if (self.playback) |device| device.setGain(v, self.volume.values[0..self.volume.count]);
                    self.output(.{ .kind = .mute, .recording = false, .muted = v });
                },
                .latency => |v| {
                    self.minimum_ms = v;
                    if (self.playback) |device| device.playback.setMinimumStartup(v);
                },
            }
        }
        fn recordEvent(self: *Self, value: audio.Event) !void {
            switch (value) {
                .start => |v| {
                    try wire.validate(v.configuration);
                    if (v.epoch == 0) return error.AudioStreamChanged;
                    self.stopCapture(self.capture != null);
                    const device = try self.devices.capture(self.allocator, v.configuration, self.options.maximum_queued_ms);
                    errdefer device.destroy();
                    try device.start();
                    const timestamp: u32 = @truncate(@as(u128, mach_absolute_time()) * self.timebase.numer / self.timebase.denom / 1_000_000);
                    try self.runtime.sendRecordAt(self.options.record_id, self.lifecycle, v.epoch, .{ .begin = timestamp }, &self.token);
                    self.capture = device;
                    self.record_configuration = v.configuration;
                    self.record_epoch = v.epoch;
                    self.output(.{ .kind = .started, .recording = true, .configuration = v.configuration });
                },
                .stop => self.stopCapture(true),
                .volume => |v| self.output(.{ .kind = .volume, .recording = true, .volume = v }),
                .mute => |v| self.output(.{ .kind = .mute, .recording = true, .muted = v }),
                else => {},
            }
        }
        fn reportUnderflows(self: *Self) void {
            if (self.playback) |device| {
                const current = device.playback.queue.diagnostics().underflows;
                if (current > self.reported_underflows) {
                    const delta = current - self.reported_underflows;
                    self.reported_underflows = current;
                    self.output(.{ .kind = .underrun, .recording = false, .count = delta });
                }
            }
        }
        fn drain(self: *Self) !void {
            const device = self.capture orelse return;
            const config = self.record_configuration.?;
            const result = try device.converter.queue.drain(self.allocator);
            defer result.deinit();
            if (result.failure) |failure| return switch (failure) {
                .input_format_changed => error.AudioInputFormatChanged,
                .invalid_input_storage => error.AudioInvalidInputStorage,
                .converter => error.AudioConversionFailed,
                .invalid_output_storage => error.AudioInvalidOutputStorage,
            };
            if (result.dropped_bytes > 0) self.output(.{ .kind = .overflow, .recording = true, .milliseconds = buffers.milliseconds(result.dropped_bytes / (config.channels * 2), config.frequency) });
            for (result.packets) |packet| try self.runtime.sendRecordAt(self.options.record_id, self.lifecycle, self.record_epoch, .{ .packet = .{ .time = packet.timestamp, .bytes = packet.bytes } }, &self.token);
        }
        fn snapshot(self: *Self) void {
            const play = if (self.playback) |device| device.playback.queue.diagnostics() else null;
            const capture = if (self.capture) |device| device.converter.queue.queue.diagnostics().queued_bytes else 0;
            self.mutex.lock();
            defer self.mutex.unlock();
            self.stats.queued_playback_bytes = if (play) |v| v.queued_bytes else 0;
            self.stats.underflows = if (play) |v| v.underflows else 0;
            self.stats.queued_capture_bytes = capture;
        }
        fn run(self: *Self) void {
            defer {
                self.stopPlayback(self.playback != null);
                self.stopCapture(self.capture != null);
                self.snapshot();
                self.mutex.lock();
                self.finished = true;
                self.changed.broadcast();
                self.mutex.unlock();
            }
            var capture_deadline = clock.nanoseconds(self.timebase);
            var delay_deadline = capture_deadline;
            while (true) {
                self.mutex.lock();
                if (self.stopping) {
                    self.mutex.unlock();
                    return;
                }
                var command: ?Command = null;
                if (self.count > 0) {
                    command = self.commands[self.head];
                    self.head = (self.head + 1) % self.commands.len;
                    self.count -= 1;
                    self.queued_bytes -= command.?.weight();
                }
                self.mutex.unlock();
                if (command) |value| {
                    defer value.deinit();
                    self.handle(value);
                }
                if (self.token.check()) |_| {} else |_| return;
                const now = clock.nanoseconds(self.timebase);
                if (now >= capture_deadline) {
                    self.drain() catch |err| self.fail(true, err);
                    capture_deadline = now + 2 * std.time.ns_per_ms;
                }
                if (now >= delay_deadline) {
                    if (self.playback) |device| {
                        self.reportUnderflows();
                        const config = self.playback_configuration.?;
                        const delay = buffers.milliseconds(device.playback.queue.diagnostics().queued_bytes / (config.channels * 2), config.frequency);
                        // Clock report races STOP/handoff harmlessly; this matches
                        // the existing sink's best-effort periodic report policy.
                        self.runtime.reportPlaybackDelay(self.options.playback_id, delay) catch {};
                    }
                    delay_deadline = now + @as(u64, self.options.delay_interval_ms) * std.time.ns_per_ms;
                }
                self.snapshot();
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.stopping) return;
                if (self.count > 0) continue;
                const deadline = if (self.capture != null) @min(capture_deadline, delay_deadline) else delay_deadline;
                const current = clock.nanoseconds(self.timebase);
                if (deadline > current) {
                    const wait = deadline - current;
                    const timeout: std.c.timespec = .{ .sec = @intCast(wait / std.time.ns_per_s), .nsec = @intCast(wait % std.time.ns_per_s) };
                    _ = pthread_cond_timedwait_relative_np(&self.changed.value, &self.mutex.value, &timeout);
                }
            }
        }
    };
}
