//! Serialized Agent upload state. Prepare returns owned work; completion is
//! fenced by job incarnation and phase revision. False transport admission leaves
//! state unchanged. A transport error is terminal for the affected connection;
//! callers drain failFirst rather than replay an uncertain send.
const std = @import("std");
const wire = @import("bytes.zig");
const protocol = @import("agent_services_wire.zig");
const clipboard = @import("clipboard.zig");
const agent = @import("agent.zig");
const source = @import("file_source.zig");
const cancel = @import("cancel.zig");
pub const Limits = struct { concurrent: usize = 4, maximum_bytes: u64 = 8 * 1024 * 1024 * 1024, chunk: usize = 16000 };
pub const Key = struct { id: u32, incarnation: u64 };
pub const Phase = enum { queued_start, awaiting_approval, ready_read, reading, ready_send, awaiting_completion, queued_cancel, awaiting_cancel, queued_failure };
pub const Event = union(enum) {
    queued: struct { key: Key, name: wire.Slice, total: u64 },
    awaiting_approval: Key,
    progress: struct { key: Key, sent: u64, total: u64 },
    completed: Key,
    cancelled: Key,
    failed: struct { id: ?u32, reason: anyerror, detail: ?protocol.FileDetail = null },
    pub fn deinit(self: Event) void {
        switch (self) {
            .queued => |v| v.name.release(),
            else => {},
        }
    }
};
pub const Read = struct {
    key: Key,
    revision: u64,
    source: *source.Source,
    offset: u64,
    count: usize,
    pub fn deinit(self: Read) void {
        self.source.release();
    }
    pub fn run(self: Read, a: std.mem.Allocator, token: *cancel.Token) !wire.Slice {
        return self.source.read(a, self.offset, self.count, token);
    }
};
pub const Send = struct {
    key: Key,
    revision: u64,
    message: agent.Message,
    pub fn deinit(self: Send) void {
        self.message.deinit();
    }
};
pub const Work = union(enum) {
    idle,
    read: Read,
    send: Send,
    event: Event,
    pub fn deinit(self: Work) void {
        switch (self) {
            .read => |v| v.deinit(),
            .send => |v| v.deinit(),
            .event => |v| v.deinit(),
            .idle => {},
        }
    }
};
pub const State = struct {
    const Job = struct {
        key: Key,
        revision: u64 = 1,
        phase: Phase = .queued_start,
        source: *source.Source,
        name: wire.Slice,
        total: u64,
        sent: u64 = 0,
        pending: ?wire.Slice = null,
        failure: ?anyerror = null,
        fn deinit(self: Job) void {
            self.source.release();
            self.name.release();
            if (self.pending) |v| v.release();
        }
        fn transition(self: *Job, replacement: Phase) !void {
            self.revision = try std.math.add(u64, self.revision, 1);
            self.phase = replacement;
        }
    };
    allocator: std.mem.Allocator,
    limits: Limits,
    jobs: std.AutoHashMapUnmanaged(u32, Job) = .empty,
    next_id: u32 = 1,
    next_incarnation: u64 = 0,
    pub fn init(a: std.mem.Allocator, limits: Limits) State {
        return .{ .allocator = a, .limits = .{ .concurrent = @max(1, limits.concurrent), .maximum_bytes = limits.maximum_bytes, .chunk = @min(16000, @max(1, limits.chunk)) } };
    }
    pub fn deinit(self: *State) void {
        var it = self.jobs.valueIterator();
        while (it.next()) |job| job.deinit();
        self.jobs.deinit(self.allocator);
    }
    pub fn count(self: State) usize {
        return self.jobs.count();
    }
    fn get(self: *State, key: Key) ?*Job {
        const job = self.jobs.getPtr(key.id) orelse return null;
        return if (job.key.incarnation == key.incarnation) job else null;
    }
    fn remove(self: *State, id: u32) void {
        const entry = self.jobs.fetchRemove(id) orelse return;
        entry.value.deinit();
    }
    fn failure(self: *State, id: u32, reason: anyerror, detail: ?protocol.FileDetail) Event {
        self.remove(id);
        return .{ .failed = .{ .id = id, .reason = reason, .detail = detail } };
    }
    pub fn phase(self: *State, key: Key) ?Phase {
        const job = self.get(key) orelse return null;
        return job.phase;
    }
    pub fn queue(self: *State, file: *source.Source, name: []const u8, support: clipboard.Support) !Event {
        if (!support.connected) return error.AgentUnavailable;
        if (support.file_state and !support.files) return error.FileTransferDisabled;
        if (self.jobs.count() >= self.limits.concurrent) return error.TooManyFileTransfers;
        if (file.size > self.limits.maximum_bytes) return error.FileTooLarge;
        var id = self.next_id;
        while (self.jobs.contains(id)) {
            id = if (id == std.math.maxInt(u32)) 1 else id + 1;
            if (id == self.next_id) return error.TooManyFileTransfers;
        }
        const incarnation = try std.math.add(u64, self.next_incarnation, 1);
        const validation = try protocol.encodeFileStart(self.allocator, id, name, file.size, .{});
        validation.deinit();
        const owned_name = try wire.Slice.copy(self.allocator, name);
        errdefer owned_name.release();
        const key: Key = .{ .id = id, .incarnation = incarnation };
        try self.jobs.put(self.allocator, id, .{ .key = key, .source = file, .name = owned_name, .total = file.size });
        _ = file.retain();
        self.next_id = if (id == std.math.maxInt(u32)) 1 else id + 1;
        self.next_incarnation = incarnation;
        return .{ .queued = .{ .key = key, .name = owned_name.clone(), .total = file.size } };
    }
    /// Ascending IDs match Swift's fair per-pass upload iteration.
    pub fn nextKey(self: *State, after: ?u32) ?Key {
        var best: ?Key = null;
        var it = self.jobs.valueIterator();
        while (it.next()) |job| {
            if (after) |id| {
                if (job.key.id <= id) continue;
            }
            if (best == null or job.key.id < best.?.id) best = job.key;
        }
        return best;
    }
    pub fn prepare(self: *State, key: Key, support: clipboard.Support) !Work {
        const job = self.get(key) orelse return .idle;
        if (!support.connected) return .idle;
        var message: agent.Message = undefined;
        switch (job.phase) {
            .queued_start => {
                if (!support.file_state) return .idle;
                if (!support.files) return .{ .event = self.failure(key.id, error.FileTransferDisabled, null) };
                message = try protocol.encodeFileStart(self.allocator, key.id, job.name.bytes(), job.total, .{});
            },
            .ready_read => {
                try job.transition(.reading);
                return .{ .read = .{ .key = key, .revision = job.revision, .source = job.source.retain(), .offset = job.sent, .count = @intCast(@min(job.total - job.sent, self.limits.chunk)) } };
            },
            .ready_send => message = try protocol.encodeFileData(self.allocator, key.id, job.pending.?.bytes(), .{ .chunk = self.limits.chunk }),
            .queued_cancel => message = try protocol.encodeFileStatus(self.allocator, key.id, .cancelled),
            .queued_failure => message = try protocol.encodeFileStatus(self.allocator, key.id, .failed),
            else => return .idle,
        }
        return .{ .send = .{ .key = key, .revision = job.revision, .message = message } };
    }
    /// Consumes result even when the ticket is stale or the job was cancelled.
    pub fn completeRead(self: *State, ticket: Read, result: anyerror!wire.Slice) !void {
        const job = self.get(ticket.key);
        if (job == null or job.?.phase != .reading or job.?.revision != ticket.revision) {
            if (result) |v| {
                v.release();
            } else |_| {}
            return;
        }
        const j = job.?;
        if (result) |bytes| {
            errdefer bytes.release();
            if (bytes.bytes().len != ticket.count) {
                try j.transition(.queued_failure);
                j.failure = error.FileTruncated;
                bytes.release();
                return;
            }
            try j.transition(.ready_send);
            j.pending = bytes;
        } else |err| {
            try j.transition(.queued_failure);
            j.failure = err;
        }
    }
    /// true means the entire Agent message was sent. False is no-byte admission.
    pub fn completeSend(self: *State, work: Send, sent: bool) !?Event {
        const job = self.get(work.key) orelse return null;
        if (!sent or job.revision != work.revision) return null;
        switch (job.phase) {
            .queued_start => {
                try job.transition(.awaiting_approval);
                return .{ .awaiting_approval = work.key };
            },
            .ready_send => {
                const total = try std.math.add(u64, job.sent, job.pending.?.bytes().len);
                if (total > job.total) return error.InvalidTransferState;
                try job.transition(if (total == job.total) .awaiting_completion else .ready_read);
                job.sent = total;
                job.pending.?.release();
                job.pending = null;
                return .{ .progress = .{ .key = work.key, .sent = total, .total = job.total } };
            },
            .queued_cancel => {
                try job.transition(.awaiting_cancel);
                return null;
            },
            .queued_failure => return self.failure(work.key.id, job.failure.?, null),
            else => return null,
        }
    }
    pub fn receive(self: *State, status: protocol.FileStatus) !?Event {
        const job = self.jobs.getPtr(status.id) orelse return .{ .failed = .{ .id = null, .reason = error.UnknownFileTransfer } };
        switch (status.result) {
            .can_send => {
                if (job.phase != .awaiting_approval) return self.failure(status.id, error.UnexpectedFileApproval, null);
                try job.transition(.ready_read);
                return null;
            },
            .success => {
                if (job.phase != .awaiting_completion) return self.failure(status.id, error.PrematureFileSuccess, null);
                const key = job.key;
                self.remove(status.id);
                return .{ .completed = key };
            },
            .cancelled => {
                const key = job.key;
                self.remove(status.id);
                return .{ .cancelled = key };
            },
            .failed => return self.failure(status.id, error.GuestFileError, status.detail),
            .no_space => return self.failure(status.id, error.GuestInsufficientSpace, status.detail),
            .locked => return self.failure(status.id, error.GuestSessionLocked, null),
            .disconnected => return self.failure(status.id, error.AgentUnavailable, null),
            .disabled => return self.failure(status.id, error.FileTransferDisabled, null),
        }
    }
    pub fn cancelTransfer(self: *State, key: Key) !?Event {
        const job = self.get(key) orelse return null;
        switch (job.phase) {
            .queued_start => {
                self.remove(key.id);
                return .{ .cancelled = key };
            },
            .queued_cancel, .awaiting_cancel => return null,
            else => {
                try job.transition(.queued_cancel);
                if (job.pending) |bytes| bytes.release();
                job.pending = null;
                return null;
            },
        }
    }
    pub fn failFirst(self: *State, reason: anyerror) ?Event {
        const key = self.nextKey(null) orelse return null;
        return self.failure(key.id, reason, null);
    }
};
