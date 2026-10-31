//! Transactional WebDAV admission and per-client ordering. Filesystem and send
//! owners borrow a Job until their corresponding completion call. close drops
//! queued work but cannot reclaim an in-flight syscall or sender's storage.
//! No lock is held during filesystem or transport calls; deinit requires joins.
const std = @import("std");
const http = @import("webdav_http.zig");
const sync = @import("sync.zig");
const cancel = @import("cancel.zig");
pub const Limits = struct { clients: usize = 64, jobs: usize = 64, retained_bytes: usize = 256 * 1024 * 1024, http: http.Limits = .{} };
pub const Diagnostics = struct {
    clients: usize = 0,
    buffered_bytes: usize = 0,
    pending_jobs: usize = 0,
    pending_bytes: usize = 0,
    reserved_bytes: usize = 0,
    peak_jobs: usize = 0,
    peak_bytes: usize = 0,
    completed: u64 = 0,
    cancelled: u64 = 0,
    rejected: u64 = 0,
    discarded: u64 = 0,
    pub fn retained(self: Diagnostics) usize {
        return self.buffered_bytes + self.pending_bytes + self.reserved_bytes;
    }
};
pub const Outcome = union(enum) { bytes: []u8, failure: anyerror };
pub const Job = struct {
    id: u64,
    client: i64,
    generation: u64,
    origin: u64 = 0,
    owner: u64 = 0,
    token: ?*cancel.Token = null,
    request: http.Request,
    phase: enum { queued, filesystem, ready, responding } = .queued,
    retired: bool = false,
    outcome: ?Outcome = null,
};
const Client = struct { id: i64, generation: u64, sequence: u64 = 0, legacy: bool = false, buffer: []u8 };
pub const Queue = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    mutex: sync.Mutex = .{},
    clients: std.ArrayList(Client) = .empty,
    jobs: std.ArrayList(*Job) = .empty,
    generation: u64 = 0,
    next_id: u64 = 0,
    closed: bool = false,
    // The compatibility API serializes callers, but native close may retire its
    // client while a regular-file operation is still running. Keep the ID pinned.
    legacy_active: ?i64 = null,
    stats: Diagnostics = .{},
    pub fn init(a: std.mem.Allocator, limits: Limits) !Queue {
        if (limits.clients == 0 or limits.http.header_bytes == 0 or limits.retained_bytes > std.math.maxInt(isize)) return error.InvalidLimits;
        return .{ .allocator = a, .limits = limits };
    }
    pub fn deinit(self: *Queue) void {
        std.debug.assert(self.legacy_active == null);
        for (self.jobs.items) |job| {
            std.debug.assert(job.phase == .queued or job.phase == .ready);
            self.destroyJob(job);
        }
        for (self.clients.items) |client| self.allocator.free(client.buffer);
        self.jobs.deinit(self.allocator);
        self.clients.deinit(self.allocator);
        self.mutex.deinit();
    }
    fn index(self: *Queue, id: i64) ?usize {
        for (self.clients.items, 0..) |client, i| if (client.id == id) return i;
        return null;
    }
    fn destroyJob(self: *Queue, job: *Job) void {
        job.request.deinit();
        if (job.outcome) |outcome| switch (outcome) {
            .bytes => |data| self.allocator.free(data),
            .failure => {},
        };
        self.allocator.destroy(job);
    }
    fn release(self: *Queue, job: *Job) void {
        for (self.jobs.items, 0..) |item, i| if (item == job) {
            _ = self.jobs.orderedRemove(i);
            break;
        };
        self.stats.pending_jobs -= 1;
        self.stats.pending_bytes -= job.request.retained;
        self.stats.reserved_bytes -= job.request.response_limit;
        self.destroyJob(job);
    }
    fn reject(self: *Queue, err: anyerror) anyerror {
        self.stats.rejected +|= 1;
        return err;
    }
    /// An input batch is either fully admitted or has no effect on existing
    /// buffers, sequence numbers or requests. Parse at most one beyond capacity.
    pub fn submit(self: *Queue, id: i64, bytes: []const u8) !bool {
        return self.submitAt(id, bytes, 0);
    }
    /// origin belongs to completed requests in this submission; an incomplete
    /// HTTP prefix takes the origin of the later submission completing it.
    pub fn submitAt(self: *Queue, id: i64, bytes: []const u8, origin: u64) !bool {
        return self.submitFor(id, bytes, origin, 0);
    }
    pub fn submitFor(self: *Queue, id: i64, bytes: []const u8, origin: u64, owner: u64) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.Closed;
        if (bytes.len == 0) return false;
        if (self.legacy_active == id) return error.InvalidRequest;
        const existing = self.index(id);
        if (existing) |i| if (self.clients.items[i].legacy) return error.InvalidRequest;
        if (existing == null and self.clients.items.len >= self.limits.clients) return self.reject(error.TooManyClients);
        if (existing == null and self.generation == std.math.maxInt(u64)) return error.InvalidRequest;
        const previous = if (existing) |i| self.clients.items[i].buffer else &.{};
        const total_without = self.stats.retained() - previous.len;
        const size = std.math.add(usize, previous.len, bytes.len) catch return self.reject(error.RetainedBytesExceeded);
        if (size > self.limits.retained_bytes - total_without) return self.reject(error.RetainedBytesExceeded);
        const candidate = try self.allocator.alloc(u8, size);
        defer self.allocator.free(candidate);
        @memcpy(candidate[0..previous.len], previous);
        @memcpy(candidate[previous.len..], bytes);
        var added: std.ArrayList(*Job) = .empty;
        defer added.deinit(self.allocator);
        errdefer for (added.items) |job| self.destroyJob(job);
        var sequence = if (existing) |i| self.clients.items[i].sequence else 0;
        const generation = if (existing) |i| self.clients.items[i].generation else self.generation + 1;
        var offset: usize = 0;
        var pending: usize = 0;
        var reserved: usize = 0;
        while (try http.next(self.allocator, candidate[offset..], sequence, self.limits.http)) |request| {
            errdefer request.deinit();
            if (added.items.len >= self.limits.jobs - self.stats.pending_jobs) return self.reject(error.TooManyPendingJobs);
            const next_pending = std.math.add(usize, pending, request.retained) catch return self.reject(error.RetainedBytesExceeded);
            const next_reserved = std.math.add(usize, reserved, request.response_limit) catch return self.reject(error.RetainedBytesExceeded);
            const job = try self.allocator.create(Job);
            errdefer self.allocator.destroy(job);
            job.* = .{ .id = 0, .client = id, .generation = generation, .origin = origin, .owner = owner, .request = request };
            try added.append(self.allocator, job);
            sequence = request.sequence;
            offset += request.consumed;
            pending = next_pending;
            reserved = next_reserved;
        }
        const remaining = candidate.len - offset;
        const added_retained = std.math.add(usize, pending, reserved) catch return self.reject(error.RetainedBytesExceeded);
        if (remaining > self.limits.retained_bytes - total_without or added_retained > self.limits.retained_bytes - total_without - remaining) return self.reject(error.RetainedBytesExceeded);
        const end_id = std.math.add(u64, self.next_id, added.items.len) catch return error.InvalidRequest;
        const new_buffer = try self.allocator.dupe(u8, candidate[offset..]);
        errdefer self.allocator.free(new_buffer);
        try self.jobs.ensureUnusedCapacity(self.allocator, added.items.len);
        if (existing == null) try self.clients.ensureUnusedCapacity(self.allocator, 1);
        // No fallible operation follows publication.
        const client: Client = .{ .id = id, .generation = generation, .sequence = sequence, .buffer = new_buffer };
        if (existing) |i| {
            self.allocator.free(self.clients.items[i].buffer);
            self.clients.items[i] = client;
        } else {
            self.clients.appendAssumeCapacity(client);
            self.generation = generation;
        }
        self.stats.clients = self.clients.items.len;
        for (added.items, self.next_id..) |job, job_id| {
            job.id = job_id;
            self.jobs.appendAssumeCapacity(job);
        }
        self.next_id = end_id;
        self.stats.buffered_bytes = self.stats.buffered_bytes - previous.len + remaining;
        self.stats.pending_jobs += added.items.len;
        self.stats.pending_bytes += pending;
        self.stats.reserved_bytes += reserved;
        self.stats.peak_jobs = @max(self.stats.peak_jobs, self.stats.pending_jobs);
        self.stats.peak_bytes = @max(self.stats.peak_bytes, self.stats.retained());
        return added.items.len != 0;
    }
    /// Returns one runnable client head. Same-ID reuse waits for both retired
    /// filesystem and send owners, even if the newer client has already submitted.
    pub fn takeFilesystem(self: *Queue) ?*Job {
        return self.takeFilesystemFor(0, null);
    }
    pub fn takeFilesystemFor(self: *Queue, owner: u64, token: ?*cancel.Token) ?*Job {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.jobs.items, 0..) |job, i| {
            if (job.phase != .queued or job.owner != owner) continue;
            var blocked = false;
            for (self.jobs.items[0..i]) |earlier| if (earlier.client == job.client) {
                blocked = true;
                break;
            };
            if (blocked) continue;
            job.phase = .filesystem;
            job.token = token;
            return job;
        }
        return null;
    }
    /// Consumes outcome storage unconditionally and the filesystem borrow.
    /// A retired result is discarded without being offered to a sender.
    pub fn filesystemDone(self: *Queue, job: *Job, outcome: Outcome) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(job.phase == .filesystem);
        job.outcome = outcome;
        if (job.retired) {
            self.stats.cancelled +|= 1;
            self.stats.discarded +|= 1;
            self.release(job);
            return;
        }
        if (outcome == .bytes and outcome.bytes.len > job.request.response_limit) {
            self.allocator.free(outcome.bytes);
            job.outcome = .{ .failure = error.BodyTooLarge };
        }
        job.phase = .ready;
    }
    pub fn takeResponse(self: *Queue) ?*Job {
        return self.takeResponseID(null);
    }
    pub fn takeResponseID(self: *Queue, id: ?u64) ?*Job {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.jobs.items) |job| if (job.phase == .ready and (id == null or id.? == job.id)) {
            job.phase = .responding;
            return job;
        };
        return null;
    }
    /// Consumes the send borrow. An uncertain send terminates the generation;
    /// later mutating requests must not execute after failed delivery.
    pub fn responseDone(self: *Queue, job: *Job, delivered: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(job.phase == .responding);
        const id = job.client;
        const generation = job.generation;
        if (!delivered) self.stats.cancelled +|= 1 else if (job.outcome.? == .bytes) self.stats.completed +|= 1;
        self.release(job);
        if (!delivered) if (self.index(id)) |i| {
            if (self.clients.items[i].generation == generation) self.closeLocked(id);
        };
    }
    fn closeLocked(self: *Queue, id: i64) void {
        const i = self.index(id) orelse return;
        const client = self.clients.orderedRemove(i);
        self.stats.buffered_bytes -= client.buffer.len;
        self.allocator.free(client.buffer);
        self.stats.clients = self.clients.items.len;
        var index_job: usize = 0;
        while (index_job < self.jobs.items.len) {
            const job = self.jobs.items[index_job];
            if (job.client == id and job.generation == client.generation) {
                if (job.phase == .queued or job.phase == .ready) {
                    self.stats.cancelled +|= 1;
                    self.release(job);
                    continue;
                }
                job.retired = true;
                // Registrations only wake transport waiters; they must never
                // enter this queue or its executor gate.
                if (job.token) |token| token.cancel();
            }
            index_job += 1;
        }
    }
    pub fn close(self: *Queue, id: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closeLocked(id);
    }
    /// Serialized compatibility input shares client and memory admission with
    /// native workers. It intentionally parses one request at a time, retaining
    /// the original API's consumed-prefix semantics and unlimited batch length.
    pub fn beginLegacy(self: *Queue, id: i64, bytes: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.Closed;
        if (self.legacy_active != null) return error.InvalidRequest;
        const existing = self.index(id);
        if (existing) |i| {
            if (!self.clients.items[i].legacy) return error.InvalidRequest;
        } else {
            for (self.jobs.items) |job| if (job.client == id) return error.InvalidRequest;
            if (self.clients.items.len >= self.limits.clients) return error.TooManyClients;
            if (self.generation == std.math.maxInt(u64)) return error.InvalidRequest;
        }
        const previous: []const u8 = if (existing) |i| self.clients.items[i].buffer else &.{};
        if (bytes.len > self.limits.retained_bytes - self.stats.retained()) return error.BodyTooLarge;
        const next = try self.allocator.alloc(u8, previous.len + bytes.len);
        errdefer self.allocator.free(next);
        @memcpy(next[0..previous.len], previous);
        @memcpy(next[previous.len..], bytes);
        if (existing) |i| {
            self.allocator.free(self.clients.items[i].buffer);
            self.clients.items[i].buffer = next;
        } else {
            try self.clients.append(self.allocator, .{ .id = id, .generation = self.generation + 1, .legacy = true, .buffer = next });
            self.generation += 1;
        }
        self.stats.clients = self.clients.items.len;
        self.stats.buffered_bytes += bytes.len;
        self.stats.peak_bytes = @max(self.stats.peak_bytes, self.stats.retained());
        self.legacy_active = id;
    }
    pub fn nextLegacy(self: *Queue, id: i64) !?http.Request {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.legacy_active == id);
        const i = self.index(id) orelse return null;
        const client = &self.clients.items[i];
        std.debug.assert(client.legacy);
        const request = try http.next(self.allocator, client.buffer, 0, self.limits.http) orelse return null;
        errdefer request.deinit();
        const remaining = try self.allocator.dupe(u8, client.buffer[request.consumed..]);
        self.allocator.free(client.buffer);
        client.buffer = remaining;
        self.stats.buffered_bytes -= request.consumed;
        return request;
    }
    pub fn endLegacy(self: *Queue, id: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.legacy_active == id);
        self.legacy_active = null;
    }
    /// Reset clients while preserving active borrows and allowing later reuse.
    pub fn closeAll(self: *Queue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.clients.items.len != 0) self.closeLocked(self.clients.items[0].id);
    }
    /// Irreversible shutdown; external owners still need completion and joins.
    pub fn stop(self: *Queue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        while (self.clients.items.len != 0) self.closeLocked(self.clients.items[0].id);
    }
    pub fn diagnostics(self: *Queue) Diagnostics {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }
};
