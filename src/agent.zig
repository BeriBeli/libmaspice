//! Bounded VDAgent byte stream and outbound whole-message serialization.
//! Decoder belongs to one receive worker; Sender supports concurrent producers,
//! receives token/lifecycle updates, and pins every message to one connection.
const std = @import("std");
const wire = @import("bytes.zig");
const channels = @import("channel.zig");
const sync = @import("sync.zig");
pub const Limits = struct { packet: usize = 2048, data: usize = 16 * 1024 * 1024 };
pub const Message = struct {
    protocol: u32 = 1,
    kind: u32,
    opaque_id: u64 = 0,
    // Receive-side Agent incarnation; never serialized onto the wire.
    epoch: u64 = 0,
    data: wire.Slice,
    pub fn deinit(self: Message) void {
        self.data.release();
    }
};
pub const Messages = struct {
    allocator: std.mem.Allocator,
    items: []Message,
    pub fn deinit(self: Messages) void {
        for (self.items) |message| message.deinit();
        self.allocator.free(self.items);
    }
};
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    limits: Limits = .{},
    buffered: std.ArrayList(u8) = .empty,
    pub fn reset(self: *Decoder) void {
        self.buffered.deinit(self.allocator);
        self.buffered = .empty;
    }
    pub fn deinit(self: *Decoder) void {
        self.reset();
    }
    /// A malformed/allocation-failed append is terminal for this agent epoch;
    /// it drops its partial assembly, never replays an already delivered prefix.
    pub fn append(self: *Decoder, packet: []const u8) !Messages {
        errdefer self.reset();
        if (packet.len > self.limits.packet) return error.MessageTooLarge;
        const maximum = try std.math.add(usize, try std.math.add(usize, self.limits.data, 20), self.limits.packet);
        if (self.buffered.items.len > maximum or packet.len > maximum - self.buffered.items.len) return error.MessageTooLarge;
        try self.buffered.appendSlice(self.allocator, packet);
        var messages: std.ArrayList(Message) = .empty;
        errdefer {
            for (messages.items) |m| m.deinit();
            messages.deinit(self.allocator);
        }
        var consumed: usize = 0;
        while (self.buffered.items.len - consumed >= 20) {
            var reader = try wire.Reader.init(self.buffered.items, consumed);
            const protocol = try reader.read(u32);
            const kind = try reader.read(u32);
            const opaque_id = try reader.read(u64);
            const size = try reader.read(u32);
            if (size > self.limits.data) return error.MessageTooLarge;
            if (reader.remaining() < size) break;
            const data = try wire.Slice.copy(self.allocator, try reader.take(size));
            errdefer data.release();
            try messages.append(self.allocator, .{ .protocol = protocol, .kind = kind, .opaque_id = opaque_id, .data = data });
            consumed = reader.offset;
        }
        const result = try messages.toOwnedSlice(self.allocator);
        const remaining = self.buffered.items.len - consumed;
        std.mem.copyForwards(u8, self.buffered.items[0..remaining], self.buffered.items[consumed..]);
        self.buffered.items.len = remaining;
        if (remaining == 0) self.reset();
        return .{ .allocator = self.allocator, .items = result };
    }
};
pub const SendToken = struct { cancelled: bool = false }; // Sender.mutex
const Turn = struct { next: ?*Turn = null, token: *SendToken, generation: u64, connection: ?*channels.Channel = null };
pub const Sender = struct {
    allocator: std.mem.Allocator,
    connection: *channels.Channel,
    limits: Limits = .{},
    mutex: sync.Mutex = .{},
    changed: sync.Condition = .{},
    connected: bool = false,
    stopped: bool = false,
    generation: u64 = 0,
    tokens: u64 = 0,
    head: ?*Turn = null,
    tail: ?*Turn = null,
    active: ?*Turn = null,
    queued: usize = 0,
    /// All callers joined before deinit. Cancel stops the transport as well.
    pub fn deinit(self: *Sender) void {
        self.cancel();
        std.debug.assert(self.active == null and self.head == null);
        self.changed.deinit();
        self.mutex.deinit();
    }
    pub fn cancel(self: *Sender) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopped = true;
        self.connection.cancel();
        if (self.active) |turn| {
            if (turn.connection) |connection| connection.cancel();
        }
        self.changed.broadcast();
    }
    pub fn cancelSend(self: *Sender, token: *SendToken) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        token.cancelled = true;
        if (self.active) |turn| {
            if (turn.token == token) {
                if (turn.connection) |connection| connection.cancel();
            }
        }
        self.changed.broadcast();
    }
    pub fn epoch(self: *Sender) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.generation;
    }
    pub fn start(self: *Sender, tokens: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopped) return error.Cancelled;
        if (self.connected) return error.InvalidAgentState;
        self.generation = try std.math.add(u64, self.generation, 1);
        self.connected = true;
        self.tokens = tokens;
        self.changed.broadcast();
    }
    pub fn reset(self: *Sender) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.connected = false;
        self.tokens = 0;
        // No wrap may make an old send ticket current again.
        if (self.generation == std.math.maxInt(u64)) self.stopped = true else self.generation += 1;
        self.changed.broadcast();
    }
    pub fn addTokens(self: *Sender, tokens: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.connected or self.stopped) return error.InvalidAgentState;
        self.tokens = try std.math.add(u64, self.tokens, tokens);
    }
    pub fn rebind(self: *Sender, replacement: *channels.Channel) !*channels.Channel {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.connection.key.index() != replacement.key.index()) return error.InvalidState;
        try replacement.activate();
        const previous = self.connection;
        previous.supersede(previous.barrier == replacement.barrier);
        self.connection = replacement;
        return previous;
    }
    pub fn waitRetired(self: *Sender, connection: *channels.Channel) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.active) |turn| {
            if (turn.connection != connection) return;
            if (self.stopped) return error.Cancelled;
            self.changed.wait(&self.mutex);
        }
    }
    fn remove(self: *Sender, turn: *Turn) void {
        var slot = &self.head;
        var previous: ?*Turn = null;
        while (slot.*) |entry| {
            if (entry == turn) {
                slot.* = entry.next;
                if (self.tail == turn) self.tail = previous;
                self.queued -= 1;
                return;
            }
            previous = entry;
            slot = &entry.next;
        }
        unreachable;
    }
    /// False means insufficient tokens and emits no bytes. Each true result is
    /// one complete message; its packets cannot interleave with another producer.
    pub fn send(self: *Sender, protocol: u32, kind: u32, opaque_id: u64, data: []const u8, token: *SendToken) !bool {
        return self.sendAt(null, protocol, kind, opaque_id, data, token);
    }
    pub fn sendAt(self: *Sender, expected_epoch: ?u64, protocol: u32, kind: u32, opaque_id: u64, data: []const u8, token: *SendToken) !bool {
        if (self.limits.packet == 0 or data.len > self.limits.data or data.len > std.math.maxInt(u32)) return error.MessageTooLarge;
        const total = try std.math.add(usize, data.len, 20);
        const required = (total - 1) / self.limits.packet + 1;
        var output: wire.Writer = .{ .allocator = self.allocator, .limit = total };
        defer output.deinit();
        try output.write(u32, protocol);
        try output.write(u32, kind);
        try output.write(u64, opaque_id);
        try output.write(u32, @intCast(data.len));
        try output.append(data);
        self.mutex.lock();
        if (token.cancelled or self.stopped) {
            self.mutex.unlock();
            return error.Cancelled;
        }
        if (!self.connected) {
            self.mutex.unlock();
            return error.InvalidAgentState;
        }
        if (expected_epoch) |expected| {
            if (self.generation != expected) {
                self.mutex.unlock();
                return error.StaleAgentGeneration;
            }
        }
        if (self.tokens < required) {
            self.mutex.unlock();
            return false;
        }
        if (self.queued >= 64) {
            self.mutex.unlock();
            return error.TooManySenders;
        }
        self.tokens -= required;
        var turn: Turn = .{ .token = token, .generation = self.generation };
        if (self.tail) |tail| tail.next = &turn else self.head = &turn;
        self.tail = &turn;
        self.queued += 1;
        var sent: usize = 0;
        // State mutex is held on entry/exit of this scope, released for writes.
        defer {
            if (self.active == &turn) self.active = null else self.remove(&turn);
            if (sent == 0 and turn.generation == self.generation) {
                self.tokens = std.math.add(u64, self.tokens, required) catch blk: {
                    self.stopped = true;
                    self.connection.cancel();
                    break :blk 0;
                };
            }
            self.changed.broadcast();
            self.mutex.unlock();
        }
        while (self.active != null or self.head != &turn) {
            if (token.cancelled or self.stopped) return error.Cancelled;
            if (turn.generation != self.generation or !self.connected) return error.InvalidAgentState;
            self.changed.wait(&self.mutex);
        }
        if (token.cancelled or self.stopped) return error.Cancelled;
        if (turn.generation != self.generation or !self.connected) return error.InvalidAgentState;
        self.remove(&turn);
        self.active = &turn;
        turn.connection = self.connection;
        errdefer {
            if (sent > 0 and sent < required and turn.generation == self.generation) {
                self.connected = false;
                self.tokens = 0;
                if (self.generation == std.math.maxInt(u64)) self.stopped = true else self.generation += 1;
                turn.connection.?.cancel();
            }
        }
        var offset: usize = 0;
        while (offset < output.bytes.items.len) {
            if (token.cancelled or self.stopped) return error.Cancelled;
            if (turn.generation != self.generation or !self.connected) return error.InvalidAgentState;
            const end = offset + @min(self.limits.packet, output.bytes.items.len - offset);
            self.mutex.unlock();
            const result = turn.connection.?.sendRetiring(107, output.bytes.items[offset..end]);
            self.mutex.lock();
            try result;
            sent += 1;
            offset = end;
            if (turn.generation != self.generation or !self.connected) return error.InvalidAgentState;
        }
        return true;
    }
};
