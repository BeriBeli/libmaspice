//! Session-owned connection registry and cancellation boundary. All connections,
//! including ones still establishing TLS/auth, are registered before blocking.
//! cancel is concurrent/idempotent; destroy requires callers and waiters joined.
//! Each receive/handler sequence remains confined to its channel worker. This is
//! the ownership layer; Main bootstrap and typed channel services build on it.
const std = @import("std");
const sync = @import("sync.zig");
const network = @import("transport.zig");
const link = @import("link.zig");
const channels = @import("channel.zig");
const clock = @import("clock.zig");
const barriers = @import("barrier.zig");
pub const Connection = struct {
    owner: *Session,
    transport: *network.Transport,
    negotiated: ?link.Negotiated = null,
    channel: channels.Channel = undefined,
    key: barriers.Key,
    ready: bool = false, // registry mutex; immutable after successful connect
    next: ?*Connection = null,
};
pub const Session = struct {
    allocator: std.mem.Allocator,
    barrier: *barriers.Barrier,
    clock: clock.Clock,
    mutex: sync.Mutex = .{},
    connections: ?*Connection = null,
    count: usize = 0,
    cancelled: bool = false,
    maximum_channels: usize,
    pub fn create(allocator: std.mem.Allocator, maximum_channels: usize) !*Session {
        if (maximum_channels == 0 or maximum_channels > 65536) return error.InvalidConfiguration;
        const multimedia_clock = try clock.Clock.init();
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .barrier = try barriers.Barrier.create(allocator), .maximum_channels = maximum_channels, .clock = multimedia_clock };
        return self;
    }
    pub fn isCancelled(self: *Session) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cancelled;
    }
    pub fn cancel(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cancelled = true;
        self.barrier.cancelAll();
        self.clock.cancel();
        var current = self.connections;
        while (current) |connection| : (current = connection.next) {
            if (connection.ready) connection.channel.cancel() else connection.transport.cancel();
        }
    }
    pub fn destroy(self: *Session) void {
        self.cancel();
        while (self.connections) |connection| {
            self.connections = connection.next;
            self.dispose(connection);
        }
        self.clock.deinit();
        self.barrier.destroy();
        self.mutex.deinit();
        self.allocator.destroy(self);
    }
    fn dispose(self: *Session, connection: *Connection) void {
        if (connection.ready) connection.channel.deinit();
        if (connection.negotiated) |negotiated| negotiated.deinit();
        connection.transport.destroy();
        self.allocator.destroy(connection);
    }
    fn insert(self: *Session, connection: *Connection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.cancelled) return error.Cancelled;
        if (self.count >= self.maximum_channels) return error.TooManyChannels;
        var current = self.connections;
        while (current) |existing| : (current = existing.next) {
            if (existing.key.index() == connection.key.index()) return error.DuplicateChannel;
        }
        connection.next = self.connections;
        self.connections = connection;
        self.count += 1;
    }
    fn removeFailed(self: *Session, connection: *Connection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var slot = &self.connections;
        while (slot.*) |current| {
            if (current == connection) {
                slot.* = current.next;
                self.count -= 1;
                return;
            }
            slot = &current.next;
        }
        unreachable;
    }
    /// Copies endpoint/TLS inputs. Password and request capabilities are borrowed
    /// only until this call returns. No session credential copy is retained.
    pub fn connect(self: *Session, host: []const u8, port: u16, tls: network.tls.Config, timeout_ms: u32, request: link.Request, password: []const u8) !*Connection {
        const transport = try network.Transport.create(self.allocator, host, port, tls, timeout_ms);
        errdefer transport.destroy();
        const connection = try self.allocator.create(Connection);
        errdefer self.allocator.destroy(connection);
        connection.* = .{ .owner = self, .transport = transport, .key = .{ .kind = request.channel_type, .id = request.channel_id } };
        try self.insert(connection);
        errdefer self.removeFailed(connection);
        const negotiated = try link.perform(self.allocator, transport, request, password);
        errdefer negotiated.deinit();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.cancelled) return error.Cancelled;
        connection.negotiated = negotiated;
        connection.channel = channels.Channel.init(self.allocator, connection.key, channels.IO.native(transport), negotiated.mode(), self.barrier);
        connection.ready = true;
        return connection;
    }
};
