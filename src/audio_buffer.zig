//! Playback startup/underflow policy and capture reporting. Apple callback
//! adapters borrow these fixed owners; destruction requires joined callbacks.
const std = @import("std");
const ring = @import("audio_ring.zig");
const sync = @import("sync.zig");
pub fn milliseconds(frames: u64, rate: u32) u32 {
    if (rate == 0) return 0;
    return @intCast(@min(std.math.maxInt(u32), (@as(u128, frames) * 1000 + rate - 1) / rate));
}
pub const Playback = struct {
    queue: ring.Ring,
    gate: sync.Mutex = .{},
    bytes_per_frame: usize,
    sample_rate: u32,
    minimum_startup_bytes: usize,
    primed: bool = false,
    pub fn init(allocator: std.mem.Allocator, capacity: ring.Capacity, bytes_per_frame: usize, rate: u32, minimum_ms: u32) !Playback {
        if (bytes_per_frame == 0 or rate == 0 or bytes_per_frame > capacity.bytes) return error.InvalidAudioCapacity;
        return .{ .queue = try ring.Ring.init(allocator, capacity, true), .bytes_per_frame = bytes_per_frame, .sample_rate = rate, .minimum_startup_bytes = startup(capacity.bytes, rate, bytes_per_frame, minimum_ms) };
    }
    pub fn deinit(self: *Playback) void {
        self.queue.deinit();
        self.gate.deinit();
    }
    fn startup(capacity: usize, rate: u32, frame_bytes: usize, ms: u32) usize {
        return @intCast(@min(capacity, ((@as(u128, ms) * rate + 999) / 1000) * frame_bytes));
    }
    fn publish(self: *Playback, commit: *ring.Ring.Commit) ring.Result {
        self.gate.lock();
        defer self.gate.unlock();
        const result = commit.publish();
        switch (result) {
            .enqueued => |info| {
                if (info.dropped_packets > 0 or info.dropped_bytes > 0) self.primed = false;
            },
            else => {},
        }
        return result;
    }
    pub fn enqueue(self: *Playback, timestamp: u32, bytes: []const u8) ring.Result {
        return self.queue.enqueueStaged(timestamp, bytes, null, self, publish);
    }
    pub fn setMinimumStartup(self: *Playback, ms: u32) void {
        self.gate.lock();
        defer self.gate.unlock();
        self.minimum_startup_bytes = startup(self.queue.storage.len, self.sample_rate, self.bytes_per_frame, ms);
    }
    pub fn render(self: *Playback, destination: []u8) usize {
        if (destination.len == 0) return 0;
        @memset(destination, 0);
        self.gate.lock();
        defer self.gate.unlock();
        const queued = self.queue.diagnostics().queued_bytes;
        if (!self.primed) {
            if (queued == 0 or queued < self.minimum_startup_bytes) return 0;
            self.primed = true;
        }
        const copied = self.queue.read(destination);
        if (copied < destination.len) self.primed = false;
        return copied;
    }
    pub fn close(self: *Playback) void {
        self.gate.lock();
        defer self.gate.unlock();
        self.queue.close();
        self.primed = false;
    }
};
pub const CaptureFailure = enum { input_format_changed, invalid_input_storage, converter, invalid_output_storage };
pub const Capture = struct {
    queue: ring.Ring,
    reporting: sync.Mutex = .{},
    reported_dropped: u64 = 0,
    failure: ?CaptureFailure = null,
    pub const Drain = struct {
        allocator: std.mem.Allocator,
        packets: []ring.Packet,
        allocation: []ring.Packet,
        dropped_bytes: u64,
        failure: ?CaptureFailure,
        pub fn deinit(self: Drain) void {
            for (self.packets) |packet| packet.deinit();
            self.allocator.free(self.allocation);
        }
    };
    pub fn init(allocator: std.mem.Allocator, capacity: ring.Capacity) !Capture {
        return .{ .queue = try ring.Ring.init(allocator, capacity, false) };
    }
    pub fn deinit(self: *Capture) void {
        self.queue.deinit();
        self.reporting.deinit();
    }
    pub fn fail(self: *Capture, failure: CaptureFailure) void {
        self.reporting.lock();
        defer self.reporting.unlock();
        if (self.failure == null) self.failure = failure;
    }
    /// Allocation failure before any dequeue leaves the queue unchanged. A
    /// later failure returns the successfully materialized prefix; the failed
    /// packet stays queued for the next drain. Reports accompany the returned prefix.
    pub fn drain(self: *Capture, allocator: std.mem.Allocator) !Drain {
        const limit = self.queue.diagnostics().queued_slots;
        var packets: std.ArrayList(ring.Packet) = .empty;
        try packets.ensureTotalCapacityPrecise(allocator, limit);
        errdefer {
            for (packets.items) |packet| packet.deinit();
            packets.deinit(allocator);
        }
        for (0..limit) |_| {
            const packet = self.queue.dequeue(allocator) catch |err| {
                if (packets.items.len == 0) return err;
                break;
            };
            if (packet) |value| packets.appendAssumeCapacity(value) else break;
        }
        const allocation = packets.allocatedSlice();
        const owned = packets.items;
        const dropped = self.queue.diagnostics().dropped_bytes;
        self.reporting.lock();
        defer self.reporting.unlock();
        const delta = dropped -| self.reported_dropped;
        self.reported_dropped = dropped;
        const failure = self.failure;
        self.failure = null;
        return .{ .allocator = allocator, .packets = owned, .allocation = allocation, .dropped_bytes = delta, .failure = failure };
    }
    pub fn reset(self: *Capture) void {
        self.queue.reset();
        const dropped = self.queue.diagnostics().dropped_bytes;
        self.reporting.lock();
        defer self.reporting.unlock();
        self.reported_dropped = dropped;
        self.failure = null;
    }
    pub fn close(self: *Capture) void {
        self.queue.close();
        self.reporting.lock();
        defer self.reporting.unlock();
        self.failure = null;
    }
};
