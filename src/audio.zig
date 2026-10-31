//! Existing RAW S16 playback/record contracts. Wire services do not pretend to
//! open audio hardware; consumer sinks/capture hosts are separate boundaries.
const std = @import("std");
const sync = @import("sync.zig");
const wire = @import("bytes.zig");
const audio = @import("audio_wire.zig");
const clock = @import("clock.zig");
pub const Event = union(enum) {
    mode: u32,
    start: audio.Start,
    packet: struct { time: u32, data: wire.Slice },
    stop,
    volume: audio.Volume,
    mute: bool,
    latency: u32,
    pub fn deinit(self: Event) void {
        if (self == .packet) self.packet.data.release();
    }
    pub fn weight(self: Event) usize {
        return if (self == .packet) self.packet.data.retainedBytes() else 0;
    }
};
pub const Playback = struct {
    allocator: std.mem.Allocator,
    media: *clock.Clock,
    mutex: sync.Mutex = .{},
    raw: bool = false,
    configuration: ?audio.Configuration = null,
    last_time: ?u32 = null,
    pub fn init(a: std.mem.Allocator, media: *clock.Clock) Playback {
        return .{ .allocator = a, .media = media };
    }
    pub fn deinit(self: *Playback) void {
        self.media.stopPlayback();
        self.mutex.deinit();
    }
    pub fn reportDelay(self: *Playback, delay: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.configuration == null) return error.AudioStopped;
        self.media.synchronize(self.last_time orelse return error.NoAudioData, delay);
    }
    pub fn apply(self: *Playback, command: audio.Command) !Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        return switch (command) {
            .mode => |v| blk: {
                if (v.kind != 1) return error.UnsupportedAudioMode;
                if (v.bytes.len != 0) return error.InvalidRawMode;
                self.raw = true;
                break :blk .{ .mode = v.time };
            },
            .start => |v| blk: {
                if (self.configuration != null) return error.AudioAlreadyStarted;
                if (!self.raw) return error.AudioModeRequired;
                try audio.validate(v.configuration);
                self.configuration = v.configuration;
                self.last_time = null;
                break :blk .{ .start = v };
            },
            .packet => |v| blk: {
                const config = self.configuration orelse return error.AudioStopped;
                try audio.validatePCM(config, v.bytes);
                const data = try wire.Slice.copy(self.allocator, v.bytes);
                self.last_time = v.time;
                break :blk .{ .packet = .{ .time = v.time, .data = data } };
            },
            .stop => blk: {
                if (self.configuration == null) return error.AudioStopped;
                self.configuration = null;
                self.last_time = null;
                self.media.stopPlayback();
                break :blk .stop;
            },
            .volume => |v| .{ .volume = v },
            .mute => |v| .{ .mute = v },
            .latency => |v| .{ .latency = v },
        };
    }
};
pub const RecordInput = union(enum) { begin: u32, packet: audio.Packet };
pub const Record = struct {
    allocator: std.mem.Allocator,
    // The receive state lock never spans a write. START/STOP can invalidate a
    // pending begin while the serialized sender is blocked in the transport.
    mutex: sync.Mutex = .{},
    sender: sync.Mutex = .{},
    configuration: ?audio.Configuration = null,
    marked: bool = false,
    generation: u64 = 0,
    pub fn init(a: std.mem.Allocator) Record {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *Record) void {
        self.mutex.deinit();
        self.sender.deinit();
    }
    pub fn apply(self: *Record, command: audio.Command) !Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        return switch (command) {
            .start => |v| blk: {
                if (self.configuration != null) return error.AudioAlreadyStarted;
                try audio.validate(v.configuration);
                self.generation = try std.math.add(u64, self.generation, 1);
                self.configuration = v.configuration;
                self.marked = false;
                break :blk .{ .start = .{ .configuration = v.configuration, .time = v.time, .epoch = self.generation } };
            },
            .stop => blk: {
                if (self.configuration == null) return error.AudioStopped;
                self.configuration = null;
                self.marked = false;
                break :blk .stop;
            },
            .volume => |v| .{ .volume = v },
            .mute => |v| .{ .mute = v },
            else => error.UnsupportedMessage,
        };
    }
    fn state(self: *Record) !struct { configuration: audio.Configuration, marked: bool, generation: u64 } {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .configuration = self.configuration orelse return error.AudioStopped, .marked = self.marked, .generation = self.generation };
    }
    pub fn send(self: *Record, connection: anytype, input: RecordInput) !void {
        return self.sendAt(connection, input, null);
    }
    pub fn sendAt(self: *Record, connection: anytype, input: RecordInput, expected: ?u64) !void {
        self.sender.lock();
        defer self.sender.unlock();
        const captured = try self.state();
        if (expected) |epoch| {
            if (epoch != captured.generation) return error.AudioStreamChanged;
        }
        switch (input) {
            .begin => |time| {
                if (captured.marked) return error.AudioAlreadyMarked;
                var mode: [6]u8 = undefined;
                std.mem.writeInt(u32, mode[0..4], time, .little);
                std.mem.writeInt(u16, mode[4..6], 1, .little);
                try connection.send(102, &mode);
                // MODE has already been sent. A failed START_MARK must not be
                // silently retried as though the pair had no external effect.
                connection.send(103, mode[0..4]) catch |err| {
                    connection.cancel();
                    return err;
                };
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.configuration == null or self.generation != captured.generation) return error.AudioStreamChanged;
                self.marked = true;
            },
            .packet => |v| {
                if (!captured.marked) return error.AudioMarkRequired;
                try audio.validatePCM(captured.configuration, v.bytes);
                var output: wire.Writer = .{ .allocator = self.allocator, .limit = audio.maximum_packet + 4 };
                defer output.deinit();
                try output.write(u32, v.time);
                try output.append(v.bytes);
                try connection.send(101, output.bytes.items);
            },
        }
    }
};
