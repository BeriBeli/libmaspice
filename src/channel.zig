//! One receive/handler worker per channel; send is thread-safe and frame-ordered.
//! cancel may run concurrently. Cancel + join all callers before deinit. Returned
//! deliveries own their storage and survive channel destruction. Completion must
//! follow the handler (including its GPU/resource work), never mere reception.
const std = @import("std");
const wire = @import("bytes.zig");
const frame = @import("framer.zig");
const flow = @import("flow.zig");
const sync = @import("sync.zig");
const barriers = @import("barrier.zig");
const network = @import("transport.zig");
pub const IO = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque, []u8) anyerror!usize,
    write_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    cancel_fn: *const fn (*anyopaque) void,
    pub fn native(transport: *network.Transport) IO {
        return .{ .context = transport, .read_fn = nativeRead, .write_fn = nativeWrite, .cancel_fn = nativeCancel };
    }
    fn nativeRead(ctx: *anyopaque, buffer: []u8) !usize {
        const t: *network.Transport = @ptrCast(@alignCast(ctx));
        return t.read(buffer, 1);
    }
    fn nativeWrite(ctx: *anyopaque, bytes: []const u8) !void {
        const t: *network.Transport = @ptrCast(@alignCast(ctx));
        return t.write(bytes);
    }
    fn nativeCancel(ctx: *anyopaque) void {
        const t: *network.Transport = @ptrCast(@alignCast(ctx));
        t.cancel();
    }
};
pub const Delivery = struct {
    serial: ?u64,
    effective_serial: u64,
    kind: u16,
    body: wire.Slice,
    pub fn deinit(self: Delivery) void {
        self.body.release();
    }
};
pub const Event = union(enum) {
    message: Delivery,
    migration: ?wire.Slice,
    pub fn deinit(self: Event) void {
        switch (self) {
            .message => |m| m.deinit(),
            .migration => |m| {
                if (m) |b| b.release();
            },
        }
    }
};
pub const Channel = struct {
    allocator: std.mem.Allocator,
    key: barriers.Key,
    io: IO,
    barrier: *barriers.Barrier,
    framer: frame.Framer,
    pending: ?frame.Batch = null,
    index: usize = 0,
    effective: u64 = 0,
    in_flight: bool = false,
    completes_physical: bool = false,
    suppress_ack: bool = false,
    ack: flow.Ack = .{},
    next_implicit: u64 = 1,
    next_client: u64 = 1, // writer lock
    writer: sync.Mutex = .{},
    terminal: std.atomic.Value(bool) = .init(false),
    migrating: std.atomic.Value(bool) = .init(false),
    superseded: std.atomic.Value(bool) = .init(false),
    preserve_barrier: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, key: barriers.Key, io: IO, mode: frame.Mode, barrier: *barriers.Barrier) Channel {
        return .{ .allocator = allocator, .key = key, .io = io, .barrier = barrier, .framer = .{ .allocator = allocator, .mode = mode } };
    }
    pub fn deinit(self: *Channel) void {
        self.cancel();
        self.clearPending();
        self.framer.deinit();
        self.writer.deinit();
    }
    fn clearPending(self: *Channel) void {
        if (self.pending) |batch| batch.deinit();
        self.pending = null;
        self.index = 0;
        self.in_flight = false;
        self.suppress_ack = false;
    }
    pub fn cancel(self: *Channel) void {
        self.terminal.store(true, .release);
        self.io.cancel_fn(self.io.context);
        if (!self.preserve_barrier.load(.acquire)) self.barrier.terminate(self.key);
    }
    fn ready(self: *Channel) !void {
        if (self.terminal.load(.acquire)) return error.ConnectionClosed;
        if (self.superseded.load(.acquire)) return error.InvalidState;
    }
    /// Quiescent receive worker only. A replacement shares the session barrier.
    pub fn supersede(self: *Channel, preserve: bool) void {
        self.preserve_barrier.store(preserve, .release);
        self.superseded.store(true, .release);
        self.clearPending();
        self.framer.reset();
    }
    pub fn activate(self: *Channel) !void {
        if (self.terminal.load(.acquire)) return error.ConnectionClosed;
        self.preserve_barrier.store(false, .release);
        self.superseded.store(false, .release);
    }
    pub fn resumeMigration(self: *Channel) void {
        self.migrating.store(false, .release);
    }
    pub fn configureAck(self: *Channel, generation: u32, window: u32) void {
        self.ack.configure(generation, window);
        if (self.in_flight) self.suppress_ack = true;
    }
    pub fn send(self: *Channel, kind: u16, body: []const u8) !void {
        try self.sendFramed(kind, body, false, false);
    }
    pub fn sendRetiring(self: *Channel, kind: u16, body: []const u8) !void {
        try self.sendFramed(kind, body, true, false);
    }
    fn sendFramed(self: *Channel, kind: u16, body: []const u8, retiring: bool, completing: bool) !void {
        self.writer.lock();
        defer self.writer.unlock();
        if (self.terminal.load(.acquire)) return error.ConnectionClosed;
        if ((!retiring and self.superseded.load(.acquire)) or (self.migrating.load(.acquire) and !retiring and !completing and kind != 4 and kind != 5)) return error.InvalidState;
        if (body.len > self.framer.limits.message or body.len > std.math.maxInt(u32)) return error.MessageTooLarge;
        var output: wire.Writer = .{ .allocator = self.allocator, .limit = self.framer.limits.message + self.framer.mode.size() };
        defer output.deinit();
        const next = if (self.framer.mode == .full) std.math.add(u64, self.next_client, 1) catch return error.IntegerOverflow else self.next_client;
        if (self.framer.mode == .full) try output.write(u64, self.next_client);
        try output.write(u16, kind);
        try output.write(u32, @intCast(body.len));
        if (self.framer.mode == .full) try output.write(u32, 0);
        try output.append(body);
        self.next_client = next;
        // The body limit excludes its header. Preserve legal maximum bodies
        // while every individual transport write stays within its 64MiB limit.
        // The writer lock spans all chunks, so no other frame can interleave.
        var offset: usize = 0;
        while (offset < output.bytes.items.len) {
            const end = offset + @min(64 * 1024 * 1024, output.bytes.items.len - offset);
            self.io.write_fn(self.io.context, output.bytes.items[offset..end]) catch |err| {
                self.cancel();
                return err;
            };
            offset = end;
        }
    }
    fn physicalComplete(self: *Channel) !void {
        if (!self.suppress_ack and self.ack.didProcessBatch()) try self.sendFramed(2, &.{}, false, true);
        try self.ready();
        self.barrier.record(self.key, self.effective);
        self.suppress_ack = false;
    }
    pub fn complete(self: *Channel) !void {
        try self.ready();
        if (!self.in_flight) return error.InvalidState;
        errdefer self.cancel();
        if (self.completes_physical) try self.physicalComplete();
        self.in_flight = false;
    }
    fn receiveFramed(self: *Channel) !Delivery {
        try self.ready();
        if (self.in_flight) {
            self.cancel();
            return error.InvalidState;
        }
        errdefer self.cancel();
        while (true) {
            if (self.pending) |batch| {
                if (self.index < batch.logical.len) {
                    const logical = batch.logical[self.index];
                    const body = try batch.message.body.subslice(logical.range.start, logical.range.end - logical.range.start);
                    self.index += 1;
                    self.in_flight = true;
                    self.completes_physical = self.index == batch.logical.len;
                    return .{ .serial = batch.message.serial, .effective_serial = self.effective, .kind = logical.kind, .body = body };
                }
                self.clearPending();
            }
            if (try self.framer.nextBatch(4096)) |batch| {
                self.pending = batch;
                self.effective = batch.message.serial orelse self.next_implicit;
                if (batch.message.serial == null) self.next_implicit = std.math.add(u64, self.next_implicit, 1) catch return error.IntegerOverflow;
                if (batch.logical.len == 0) {
                    try self.physicalComplete();
                    self.clearPending();
                }
                continue;
            }
            var buffer: [65536]u8 = undefined;
            const count = try self.io.read_fn(self.io.context, &buffer);
            try self.ready();
            if (count == 0) return error.ConnectionClosed;
            if (count > buffer.len) return error.InvalidSize;
            try self.framer.append(buffer[0..count]);
        }
    }
    pub fn receive(self: *Channel) !Event {
        const message = try self.receiveFramed();
        if (message.kind != 1) {
            if (message.kind == 2) {
                message.deinit();
                self.cancel();
                return error.UnexpectedMigrationData;
            }
            return .{ .message = message };
        }
        defer message.deinit();
        errdefer self.cancel();
        var reader = try wire.Reader.init(message.body.bytes(), 0);
        const flags = try reader.read(u32);
        try reader.finish();
        if (flags & ~@as(u32, 3) != 0) return error.InvalidMigrationFlags;
        self.migrating.store(true, .release);
        if (flags & 1 != 0) try self.send(4, &.{});
        try self.complete();
        if (flags & 2 != 0) {
            const data = try self.receiveFramed();
            errdefer data.deinit();
            if (data.kind != 2) return error.UnexpectedMigrationData;
            try self.complete();
            return .{ .migration = data.body };
        }
        return .{ .migration = null };
    }
};
