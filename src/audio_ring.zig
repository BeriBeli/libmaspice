//! Fixed PCM storage. All callback paths are allocation-free. A dequeue lease
//! pins its queued range while the async consumer allocates/copies outside the
//! state mutex. Producers serialize; staged payload copies never hold the render
//! gate. Callers join all operations before deinit; the ring has a stable address.
const std = @import("std");
const sync = @import("sync.zig");
pub const maximum_payload = 16 * 1024 * 1024;
pub const maximum_slots = 262144;
pub const Capacity = struct {
    bytes: usize,
    slots: usize,
    pub fn validate(self: Capacity) !void {
        if (self.bytes == 0 or self.bytes > maximum_payload or self.slots == 0 or self.slots > maximum_slots) return error.InvalidAudioCapacity;
    }
    pub fn pcm(rate: u32, channels: u32, milliseconds: u32) !Capacity {
        if (rate == 0 or channels == 0 or milliseconds == 0) return error.InvalidAudioCapacity;
        const frames = (@as(u128, rate) * milliseconds + 999) / 1000;
        const bytes = frames * channels * 2;
        if (bytes > maximum_payload or frames > maximum_slots) return error.InvalidAudioCapacity;
        const value: Capacity = .{ .bytes = @intCast(bytes), .slots = @intCast(frames) };
        try value.validate();
        return value;
    }
};
pub const Result = union(enum) {
    enqueued: struct { dropped_packets: usize = 0, dropped_bytes: usize = 0 },
    oversized: usize,
    lease_conflict: usize,
    closed: usize,
};
pub const Diagnostics = struct {
    capacity: Capacity,
    preallocated_bytes: usize,
    staging_bytes: usize,
    queued_bytes: usize = 0,
    queued_slots: usize = 0,
    enqueued_packets: u64 = 0,
    enqueued_bytes: u64 = 0,
    dequeued_packets: u64 = 0,
    dequeued_bytes: u64 = 0,
    read_calls: u64 = 0,
    wraparound_copies: u64 = 0,
    underflows: u64 = 0,
    overruns: u64 = 0,
    dropped_packets: u64 = 0,
    dropped_bytes: u64 = 0,
    reset_count: u64 = 0,
    close_count: u64 = 0,
    lease_starts: u64 = 0,
    lease_finishes: u64 = 0,
    materializations: u64 = 0,
    materialized_bytes: u64 = 0,
    lease_conflict_drops: u64 = 0,
    blocked_reads: u64 = 0,
    blocked_dequeues: u64 = 0,
    deferred_resets: u64 = 0,
    deferred_closes: u64 = 0,
    active_lease: bool = false,
    closed: bool = false,
};
pub const Packet = struct {
    allocator: std.mem.Allocator,
    timestamp: u32,
    bytes: []u8,
    pub fn deinit(self: Packet) void {
        self.allocator.free(self.bytes);
    }
};
pub const Hook = struct {
    context: *anyopaque,
    call: *const fn (*anyopaque) void,
    fn run(self: ?Hook) void {
        if (self) |hook| hook.call(hook.context);
    }
};
const Slot = struct { timestamp: u32, length: usize, consumed: usize = 0 };
const Lease = struct { timestamp: u32, bank: usize, offset: usize, length: usize };
pub const Ring = struct {
    allocator: std.mem.Allocator,
    storage: []align(64) u8,
    staging: ?[]align(64) u8,
    slots: []Slot,
    producer: sync.Mutex = .{},
    mutex: sync.Mutex = .{},
    stats: Diagnostics,
    head: usize = 0,
    tail: usize = 0,
    read_offset: usize = 0,
    write_offset: usize = 0,
    bank: usize = 0,
    reservation: bool = false,
    pending_reset: bool = false,
    pending_close: bool = false,
    pub fn init(allocator: std.mem.Allocator, capacity: Capacity, staged: bool) !Ring {
        try capacity.validate();
        const storage = try allocator.alignedAlloc(u8, .@"64", capacity.bytes);
        errdefer allocator.free(storage);
        @memset(storage, 0);
        const staging = if (staged) try allocator.alignedAlloc(u8, .@"64", capacity.bytes) else null;
        errdefer if (staging) |buffer| allocator.free(buffer);
        if (staging) |buffer| @memset(buffer, 0);
        const slots = try allocator.alloc(Slot, capacity.slots);
        return .{ .allocator = allocator, .storage = storage, .staging = staging, .slots = slots, .stats = .{ .capacity = capacity, .preallocated_bytes = capacity.bytes * (if (staged) @as(usize, 2) else 1), .staging_bytes = if (staged) capacity.bytes else 0 } };
    }
    pub fn deinit(self: *Ring) void {
        std.debug.assert(!self.reservation and !self.stats.active_lease);
        self.allocator.free(self.storage);
        if (self.staging) |buffer| self.allocator.free(buffer);
        self.allocator.free(self.slots);
        self.mutex.deinit();
        self.producer.deinit();
        self.* = undefined;
    }
    fn clear(self: *Ring) void {
        self.head = 0;
        self.tail = 0;
        self.read_offset = 0;
        self.write_offset = 0;
        self.stats.queued_bytes = 0;
        self.stats.queued_slots = 0;
    }
    fn storageBank(self: *Ring, bank: usize) []u8 {
        return if (bank == 0) self.storage else self.staging.?;
    }
    fn advance(index: usize, distance: usize, capacity: usize) usize {
        const remaining = capacity - index;
        return if (distance < remaining) index + distance else distance - remaining;
    }
    fn copyIn(self: *Ring, bank: usize, offset: usize, source: []const u8) bool {
        const target = self.storageBank(bank);
        const first = @min(source.len, target.len - offset);
        @memcpy(target[offset..][0..first], source[0..first]);
        @memcpy(target[0 .. source.len - first], source[first..]);
        return first < source.len;
    }
    fn copyOut(self: *Ring, bank: usize, offset: usize, target: []u8) bool {
        const source = self.storageBank(bank);
        const first = @min(target.len, source.len - offset);
        @memcpy(target[0..first], source[offset..][0..first]);
        @memcpy(target[first..], source[0 .. target.len - first]);
        return first < target.len;
    }
    fn conflict(self: *Ring, size: usize) Result {
        self.stats.overruns +|= 1;
        self.stats.dropped_packets +|= 1;
        self.stats.dropped_bytes +|= size;
        self.stats.lease_conflict_drops +|= 1;
        return .{ .lease_conflict = size };
    }
    fn replacement(self: *Ring) Result {
        const result: Result = .{ .enqueued = .{ .dropped_packets = self.stats.queued_slots, .dropped_bytes = self.stats.queued_bytes } };
        self.stats.overruns +|= 1;
        self.stats.dropped_packets +|= self.stats.queued_slots;
        self.stats.dropped_bytes +|= self.stats.queued_bytes;
        self.clear();
        return result;
    }
    fn immediate(self: *Ring, size: usize) ?Result {
        if (self.stats.closed) return .{ .closed = size };
        if (size == 0) return .{ .enqueued = .{} };
        if (size > self.storage.len) {
            self.stats.dropped_packets +|= 1;
            self.stats.dropped_bytes +|= size;
            return .{ .oversized = size };
        }
        return null;
    }
    fn overflow(self: *Ring, size: usize) bool {
        return self.stats.queued_slots == self.slots.len or size > self.storage.len - self.stats.queued_bytes;
    }
    fn publish(self: *Ring, timestamp: u32, offset: usize, size: usize) void {
        if (self.stats.queued_slots == 0) {
            self.read_offset = offset;
            self.write_offset = offset;
        }
        std.debug.assert(self.write_offset == offset);
        self.slots[self.tail] = .{ .timestamp = timestamp, .length = size };
        self.tail = advance(self.tail, 1, self.slots.len);
        self.stats.queued_slots += 1;
        self.stats.queued_bytes += size;
        self.write_offset = advance(offset, size, self.storage.len);
        self.stats.enqueued_packets +|= 1;
        self.stats.enqueued_bytes +|= size;
    }
    pub fn enqueue(self: *Ring, timestamp: u32, bytes: []const u8) Result {
        self.producer.lock();
        defer self.producer.unlock();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.immediate(bytes.len)) |result| return result;
        const replacing = self.overflow(bytes.len);
        if (self.stats.active_lease and (replacing or self.pending_reset)) return self.conflict(bytes.len);
        const result: Result = if (replacing) self.replacement() else .{ .enqueued = .{} };
        if (self.copyIn(self.bank, self.write_offset, bytes)) self.stats.wraparound_copies +|= 1;
        self.publish(timestamp, self.write_offset, bytes.len);
        return result;
    }
    /// Commit is borrowed only during the synchronous publication callback. It
    /// may be invoked repeatedly (idempotent), or skipped (reservation aborted).
    pub const Commit = struct {
        ring: *Ring,
        lease: Lease,
        replaces: bool,
        wrapped: bool,
        result: ?Result = null,
        pub fn publish(self: *Commit) Result {
            if (self.result) |result| return result;
            self.result = self.apply();
            return self.result.?;
        }
        fn apply(self: *Commit) Result {
            const ring = self.ring;
            ring.mutex.lock();
            defer ring.mutex.unlock();
            std.debug.assert(ring.reservation);
            ring.reservation = false;
            if (ring.stats.closed) return .{ .closed = self.lease.length };
            if (ring.stats.active_lease and (self.replaces or ring.pending_reset)) return ring.conflict(self.lease.length);
            var result: Result = .{ .enqueued = .{} };
            if (self.replaces) {
                if (ring.stats.queued_slots > 0) result = ring.replacement() else ring.clear();
                ring.bank = self.lease.bank;
            } else {
                std.debug.assert(ring.bank == self.lease.bank);
                if (ring.write_offset != self.lease.offset) {
                    std.debug.assert(ring.stats.queued_slots == 0);
                    ring.head = 0;
                    ring.tail = 0;
                    ring.read_offset = self.lease.offset;
                    ring.write_offset = self.lease.offset;
                }
            }
            if (self.wrapped) ring.stats.wraparound_copies +|= 1;
            ring.publish(self.lease.timestamp, self.lease.offset, self.lease.length);
            return result;
        }
    };
    pub fn enqueueStaged(self: *Ring, timestamp: u32, bytes: []const u8, observer: ?Hook, context: anytype, comptime publication: fn (@TypeOf(context), *Commit) Result) Result {
        std.debug.assert(self.staging != null);
        self.producer.lock();
        defer self.producer.unlock();
        self.mutex.lock();
        if (self.immediate(bytes.len)) |result| {
            self.mutex.unlock();
            return result;
        }
        const replacing = self.overflow(bytes.len);
        if (self.stats.active_lease and (replacing or self.pending_reset)) {
            const result = self.conflict(bytes.len);
            self.mutex.unlock();
            return result;
        }
        std.debug.assert(!self.reservation);
        self.reservation = true;
        var commit: Commit = .{ .ring = self, .lease = .{ .timestamp = timestamp, .bank = if (replacing) 1 - self.bank else self.bank, .offset = if (replacing) 0 else self.write_offset, .length = bytes.len }, .replaces = replacing, .wrapped = false };
        self.mutex.unlock();
        defer {
            if (commit.result == null) {
                self.mutex.lock();
                self.reservation = false;
                self.mutex.unlock();
            }
        }
        Hook.run(observer);
        commit.wrapped = self.copyIn(commit.lease.bank, commit.lease.offset, bytes);
        return publication(context, &commit);
    }
    fn consume(self: *Ring, count: usize) void {
        if (count == 0) return;
        self.read_offset = advance(self.read_offset, count, self.storage.len);
        self.stats.queued_bytes -= count;
        self.stats.dequeued_bytes +|= count;
        const slot = &self.slots[self.head];
        slot.consumed += count;
        if (slot.consumed == slot.length) {
            self.head = advance(self.head, 1, self.slots.len);
            self.stats.queued_slots -= 1;
            self.stats.dequeued_packets +|= 1;
        }
        if (self.stats.queued_slots == 0) {
            self.head = self.tail;
            self.read_offset = self.write_offset;
        }
    }
    pub fn read(self: *Ring, destination: []u8) usize {
        if (destination.len == 0) return 0;
        @memset(destination, 0);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stats.closed) return 0;
        if (self.stats.active_lease) {
            self.stats.blocked_reads +|= 1;
            return 0;
        }
        self.stats.read_calls +|= 1;
        var copied: usize = 0;
        while (copied < destination.len and self.stats.queued_slots > 0) {
            const slot = self.slots[self.head];
            const chunk = @min(slot.length - slot.consumed, destination.len - copied);
            if (self.copyOut(self.bank, self.read_offset, destination[copied..][0..chunk])) self.stats.wraparound_copies +|= 1;
            self.consume(chunk);
            copied += chunk;
        }
        if (copied < destination.len) self.stats.underflows +|= 1;
        return copied;
    }
    pub fn dequeue(self: *Ring, allocator: std.mem.Allocator) !?Packet {
        return self.dequeueObserved(allocator, null);
    }
    pub fn dequeueObserved(self: *Ring, allocator: std.mem.Allocator, observer: ?Hook) !?Packet {
        self.mutex.lock();
        if (self.stats.active_lease) {
            self.stats.blocked_dequeues +|= 1;
            self.mutex.unlock();
            return null;
        }
        if (self.stats.closed or self.stats.queued_slots == 0) {
            self.mutex.unlock();
            return null;
        }
        const slot = self.slots[self.head];
        const lease: Lease = .{ .timestamp = slot.timestamp, .bank = self.bank, .offset = self.read_offset, .length = slot.length - slot.consumed };
        self.stats.active_lease = true;
        self.stats.lease_starts +|= 1;
        self.mutex.unlock();
        var complete = false;
        var wrapped = false;
        defer {
            self.mutex.lock();
            self.stats.active_lease = false;
            self.stats.lease_finishes +|= 1;
            if (complete) {
                if (wrapped) self.stats.wraparound_copies +|= 1;
                self.stats.materializations +|= 1;
                self.stats.materialized_bytes +|= lease.length;
                self.consume(lease.length);
            }
            if (self.pending_reset or self.pending_close) {
                self.clear();
                self.pending_reset = false;
                self.pending_close = false;
            }
            self.mutex.unlock();
        }
        Hook.run(observer);
        const bytes = try allocator.alloc(u8, lease.length);
        wrapped = self.copyOut(lease.bank, lease.offset, bytes);
        complete = true;
        return .{ .allocator = allocator, .timestamp = lease.timestamp, .bytes = bytes };
    }
    pub fn reset(self: *Ring) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stats.closed) return;
        self.stats.reset_count +|= 1;
        if (self.stats.active_lease) {
            self.pending_reset = true;
            self.stats.deferred_resets +|= 1;
        } else self.clear();
    }
    pub fn close(self: *Ring) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stats.closed) return;
        self.stats.closed = true;
        self.stats.close_count +|= 1;
        if (self.stats.active_lease) {
            self.pending_close = true;
            self.stats.deferred_closes +|= 1;
        } else self.clear();
    }
    pub fn diagnostics(self: *Ring) Diagnostics {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }
};
