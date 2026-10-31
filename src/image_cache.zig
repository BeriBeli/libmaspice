//! Shared Display image cache. Register per-ID FIFO order before decoding;
//! stage validates capacity before Surface work; commit is allocation-free.
const std = @import("std");
const sync = @import("sync.zig");
const cancel = @import("cancel.zig");
const Image = @import("image.zig").Image;
pub const Limits = struct { entries: u32 = 256, bytes: usize = 256 * 1024 * 1024, waiters: usize = 64, queued_mutations: usize = 64 };
pub const Mode = enum { cache, replace };
pub const Requirement = enum { any, lossless };
pub const Outcome = enum { staged, committed, invalidated, discarded };
/// A linear ownership token: consume exactly once with commit or abort.
pub const Mutation = struct { token: u64 };
pub const Diagnostics = struct { entries: usize, committed_bytes: usize, reserved_bytes: usize, wait_bytes: usize, mutations: usize, queued: usize, mutation_bytes: usize, waiters: usize };
pub const Cache = struct {
    const Entry = struct { image: Image, lossy: bool, refs: u32 };
    const Request = struct { token: u64, id: u64, lossy: bool, mode: Mode, bytes: usize, queued: bool, invalidated: bool = false, image: ?Image = null };
    const Waiter = struct { next: ?*Waiter = null, id: u64, requirement: Requirement, bytes: usize, result: ?Image = null, failure: ?anyerror = null, done: bool = false };
    allocator: std.mem.Allocator,
    limits: Limits,
    mutex: sync.Mutex = .{},
    changed: sync.Condition = .{},
    closed: bool = false,
    entries: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    requests: std.ArrayList(Request) = .empty,
    next_token: u64 = 0,
    committed_bytes: usize = 0,
    reserved_bytes: usize = 0,
    mutation_bytes: usize = 0,
    queued: usize = 0,
    head: ?*Waiter = null,
    waiters: usize = 0,
    wait_bytes: usize = 0,
    pub fn init(a: std.mem.Allocator, limits: Limits) !Cache {
        var self: Cache = .{ .allocator = a, .limits = .{ .entries = @max(1, limits.entries), .bytes = @max(1, limits.bytes), .waiters = @min(64, @max(1, limits.waiters)), .queued_mutations = @min(64, @max(1, limits.queued_mutations)) } };
        // Keep all entry capacity across reset. Post-Surface publication must
        // not perform allocation or depend on a failing allocator.
        try self.entries.ensureTotalCapacity(a, self.limits.entries);
        return self;
    }
    fn wake(p: *anyopaque) void {
        const self: *Cache = @ptrCast(@alignCast(p));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.changed.broadcast();
    }
    fn index(self: *Cache, token: u64) ?usize {
        for (self.requests.items, 0..) |request, i| if (request.token == token) return i;
        return null;
    }
    fn active(self: *Cache, id: u64) ?usize {
        for (self.requests.items, 0..) |request, i| if (request.id == id and !request.queued) return i;
        return null;
    }
    fn temporary(self: *Cache, adding: usize) !void {
        const first = try std.math.add(usize, self.wait_bytes, self.mutation_bytes);
        const used = try std.math.add(usize, first, self.reserved_bytes);
        if (used > self.limits.bytes or adding > self.limits.bytes - used) return error.TemporaryBytesExceeded;
    }
    pub fn begin(self: *Cache, id: u64, lossy: bool, mode: Mode, retained: usize, token: *cancel.Token) !Mutation {
        var registration: cancel.Registration = .{ .context = self, .wake = wake };
        token.register(&registration);
        defer token.unregister(&registration);
        self.mutex.lock();
        defer self.mutex.unlock();
        try token.check();
        if (self.closed) return error.Closed;
        if (mode == .replace and lossy) return error.LossyReplacement;
        try self.temporary(retained);
        const queued = self.active(id) != null;
        if (queued) {
            if (self.queued >= self.limits.queued_mutations) return error.MutationQueueLimit;
        } else {
            var count: usize = self.entries.count();
            for (self.requests.items) |request| if (!request.queued and !self.entries.contains(request.id)) {
                count += 1;
            };
            if (!self.entries.contains(id)) count += 1;
            if (count > self.limits.entries) return error.EntryLimit;
        }
        const value = self.next_token;
        const next = try std.math.add(u64, value, 1);
        try self.requests.append(self.allocator, .{ .token = value, .id = id, .lossy = lossy, .mode = mode, .bytes = retained, .queued = queued });
        self.next_token = next;
        self.mutation_bytes += retained;
        if (queued) self.queued += 1;
        errdefer if (self.index(value)) |i| self.remove(i);
        while (true) {
            try token.check();
            if (self.closed) return error.Closed;
            const i = self.index(value) orelse return error.Cleared;
            if (!self.requests.items[i].queued) return .{ .token = value };
            self.changed.wait(&self.mutex);
        }
    }
    pub fn stage(self: *Cache, mutation: Mutation, image: Image) !Outcome {
        self.mutex.lock();
        defer self.mutex.unlock();
        const i = self.index(mutation.token) orelse return error.InvalidState;
        const request = &self.requests.items[i];
        if (request.queued or request.image != null) return error.InvalidState;
        if (request.invalidated) return .invalidated;
        if (request.mode == .cache) {
            if (self.entries.get(request.id)) |entry| if (entry.refs == std.math.maxInt(u32)) return error.ReferenceOverflow;
        } else {
            const entry = self.entries.get(request.id) orelse return error.ReplacementRequiresLossy;
            if (!entry.lossy) return error.ReplacementRequiresLossy;
        }
        try self.temporary(image.pixels().len);
        try self.projected(request.id, image.pixels().len);
        request.image = image.retain();
        self.reserved_bytes += image.pixels().len;
        return .staged;
    }
    fn projected(self: *Cache, id: u64, size: usize) !void {
        var count: usize = 0;
        var bytes: usize = 0;
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            var maximum = entry.value_ptr.image.pixels().len;
            if (self.active(key)) |i| if (self.requests.items[i].image) |image| {
                maximum = @max(maximum, image.pixels().len);
            };
            if (key == id) maximum = @max(maximum, size);
            count += 1;
            bytes = try std.math.add(usize, bytes, maximum);
        }
        for (self.requests.items) |request| {
            if (request.queued or self.entries.contains(request.id)) continue;
            if (request.image) |image| {
                count += 1;
                bytes = try std.math.add(usize, bytes, if (request.id == id) @max(image.pixels().len, size) else image.pixels().len);
            } else if (request.id == id) {
                count += 1;
                bytes = try std.math.add(usize, bytes, size);
            }
        }
        if (count > self.limits.entries) return error.EntryLimit;
        if (bytes > self.limits.bytes) return error.CommittedBytesExceeded;
    }
    fn remove(self: *Cache, i: usize) void {
        const request = self.requests.orderedRemove(i);
        self.mutation_bytes -= request.bytes;
        if (request.image) |image| {
            self.reserved_bytes -= image.pixels().len;
            image.release();
        }
        if (request.queued) self.queued -= 1 else {
            for (self.requests.items) |*next| {
                if (next.id == request.id) {
                    std.debug.assert(next.queued);
                    next.queued = false;
                    self.queued -= 1;
                    break;
                }
            }
        }
        self.changed.broadcast();
    }
    pub fn commit(self: *Cache, mutation: Mutation) Outcome {
        self.mutex.lock();
        defer self.mutex.unlock();
        const i = self.index(mutation.token) orelse return .discarded;
        const request = self.requests.items[i];
        if (request.queued) return .discarded;
        defer self.remove(i);
        if (request.invalidated) return .invalidated;
        const image = request.image orelse return .discarded;
        const previous = self.entries.get(request.id);
        const refs: u32 = if (request.mode == .replace) blk: {
            const old = previous orelse return .discarded;
            if (!old.lossy) return .discarded;
            break :blk old.refs;
        } else if (previous) |old| std.math.add(u32, old.refs, 1) catch return .discarded else 1;
        if (previous) |entry| {
            self.committed_bytes -= entry.image.pixels().len;
            entry.image.release();
        }
        self.entries.putAssumeCapacity(request.id, .{ .image = image.retain(), .lossy = request.lossy, .refs = refs });
        self.committed_bytes += image.pixels().len;
        var waiter = self.head;
        while (waiter) |item| : (waiter = item.next) {
            if (!item.done and item.id == request.id and (item.requirement == .any or !request.lossy)) self.resolveWaiter(item, image.retain(), null);
        }
        std.debug.assert(self.entries.count() <= self.limits.entries and self.committed_bytes <= self.limits.bytes);
        return .committed;
    }
    pub fn abort(self: *Cache, mutation: Mutation) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.index(mutation.token)) |i| self.remove(i);
    }
    fn resolveWaiter(self: *Cache, waiter: *Waiter, result: ?Image, failure: ?anyerror) void {
        std.debug.assert(!waiter.done);
        waiter.result = result;
        waiter.failure = failure;
        waiter.done = true;
        self.waiters -= 1;
        self.wait_bytes -= waiter.bytes;
    }
    pub fn resolve(self: *Cache, id: u64, requirement: Requirement, retained: usize, token: *cancel.Token) !Image {
        var registration: cancel.Registration = .{ .context = self, .wake = wake };
        token.register(&registration);
        defer token.unregister(&registration);
        self.mutex.lock();
        defer self.mutex.unlock();
        try token.check();
        if (self.closed) return error.Closed;
        if (self.entries.get(id)) |entry| if (requirement == .any or !entry.lossy) return entry.image.retain();
        if (self.waiters >= self.limits.waiters) return error.WaiterLimit;
        try self.temporary(retained);
        var waiter: Waiter = .{ .next = self.head, .id = id, .requirement = requirement, .bytes = retained };
        self.head = &waiter;
        self.waiters += 1;
        self.wait_bytes += retained;
        defer {
            var slot = &self.head;
            while (slot.*) |item| {
                if (item == &waiter) {
                    slot.* = item.next;
                    break;
                }
                slot = &item.next;
            }
            if (!waiter.done) self.resolveWaiter(&waiter, null, error.Cancelled);
        }
        while (!waiter.done) {
            try token.check();
            self.changed.wait(&self.mutex);
        }
        if (waiter.failure) |err| return err;
        return waiter.result.?;
    }
    pub fn invalidate(self: *Cache, id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.requests.items) |*request| if (request.id == id) {
            request.invalidated = true;
        };
        if (self.entries.getPtr(id)) |entry| {
            if (entry.refs > 1) entry.refs -= 1 else {
                self.committed_bytes -= entry.image.pixels().len;
                entry.image.release();
                _ = self.entries.remove(id);
            }
        }
        var waiter = self.head;
        while (waiter) |item| : (waiter = item.next) {
            if (!item.done and item.id == id) self.resolveWaiter(item, null, error.Invalidated);
        }
        self.changed.broadcast();
    }
    pub fn invalidateAll(self: *Cache) void {
        self.reset(false, false);
    }
    pub fn clear(self: *Cache) void {
        self.reset(true, false);
    }
    pub fn close(self: *Cache) void {
        self.reset(true, true);
    }
    fn reset(self: *Cache, discard: bool, closed: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (closed) self.closed = true;
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |entry| entry.image.release();
        self.entries.clearRetainingCapacity();
        self.committed_bytes = 0;
        if (discard) {
            for (self.requests.items) |request| if (request.image) |image| image.release();
            self.requests.clearRetainingCapacity();
            self.reserved_bytes = 0;
            self.mutation_bytes = 0;
            self.queued = 0;
        } else {
            for (self.requests.items) |*request| {
                request.invalidated = true;
            }
        }
        var waiter = self.head;
        while (waiter) |item| : (waiter = item.next) {
            if (!item.done) self.resolveWaiter(item, null, if (closed) error.Closed else if (discard) error.Cleared else error.Invalidated);
        }
        self.changed.broadcast();
    }
    pub fn diagnostics(self: *Cache) Diagnostics {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .entries = self.entries.count(), .committed_bytes = self.committed_bytes, .reserved_bytes = self.reserved_bytes, .wait_bytes = self.wait_bytes, .mutations = self.requests.items.len, .queued = self.queued, .mutation_bytes = self.mutation_bytes, .waiters = self.waiters };
    }
    pub fn references(self: *Cache, id: u64) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.entries.get(id)) |entry| entry.refs else 0;
    }
    /// Close, cancel and join every caller before destroying the cache.
    pub fn deinit(self: *Cache) void {
        self.close();
        std.debug.assert(self.head == null);
        self.entries.deinit(self.allocator);
        self.requests.deinit(self.allocator);
        self.changed.deinit();
        self.mutex.deinit();
    }
};
