//! Blocking worker-facing transport over asynchronous Apple Network.framework.
//! Connect/read/write may block their calling workers, never the native callback
//! queue. Creation starts the native connection; connect waits for readiness.
//! One reader + one writer may run concurrently; cancel is thread-safe.
//! The owner must cancel and JOIN callers before destroy/replacement. Verification
//! has its own immutable lifetime and may safely finish after transport teardown.
const std = @import("std");
pub const tls = @import("tls.zig");
const StateCallback = *const fn (?*anyopaque, c_int, c_int, c_int) callconv(.c) void;
const CompleteCallback = *const fn (?*anyopaque, usize, c_int, c_int, c_int) callconv(.c) void;
extern fn spice_nw_create([*:0]const u8, [*:0]const u8, c_int, ?[*:0]const u8, StateCallback, ?*anyopaque, ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) c_int, ?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) ?*anyopaque;
extern fn spice_nw_start(*anyopaque) void;
extern fn spice_nw_cancel(*anyopaque) void;
extern fn spice_nw_destroy(*anyopaque) void;
extern fn spice_nw_read(*anyopaque, [*]u8, u32, u32, CompleteCallback, ?*anyopaque) void;
extern fn spice_nw_write(*anyopaque, [*]const u8, usize, CompleteCallback, ?*anyopaque) c_int;
extern fn dispatch_semaphore_create(isize) ?*anyopaque;
extern fn dispatch_semaphore_wait(*anyopaque, u64) isize;
extern fn dispatch_semaphore_signal(*anyopaque) isize;
extern fn dispatch_time(u64, i64) u64;
extern fn dispatch_retain(*anyopaque) void;
extern fn dispatch_release(*anyopaque) void;
const forever = std.math.maxInt(u64);
pub const Error = error{ Cancelled, ConnectionClosed, ConnectionFailed, TLSFailure, Timeout, InvalidState, InvalidReadBounds, MessageTooLarge, OutOfMemory };
const Signal = struct {
    handle: *anyopaque,
    fn init() Error!Signal {
        return .{ .handle = dispatch_semaphore_create(0) orelse return error.OutOfMemory };
    }
    fn deinit(self: Signal) void {
        dispatch_release(self.handle);
    }
    fn wait(self: Signal, deadline: u64) bool {
        return dispatch_semaphore_wait(self.handle, deadline) == 0;
    }
    fn wake(self: Signal) void {
        _ = dispatch_semaphore_signal(self.handle);
    }
};
const Operation = struct {
    signal: Signal,
    size: usize = 0,
    eof: bool = false,
    domain: c_int = 0,
    code: c_int = 0,
    fn init() Error!Operation {
        return .{ .signal = try Signal.init() };
    }
    fn arm(self: *Operation) void {
        dispatch_retain(self.signal.handle);
    }
    fn complete(context: ?*anyopaque, size: usize, eof: c_int, domain: c_int, code: c_int) callconv(.c) void {
        const self: *Operation = @ptrCast(@alignCast(context.?));
        const signal = self.signal;
        self.size = size;
        self.eof = eof != 0;
        self.domain = domain;
        self.code = code;
        signal.wake();
        // Do not touch self after waking: the caller's stack can now unwind.
        signal.deinit();
    }
};

pub const Transport = struct {
    allocator: std.mem.Allocator,
    native: ?*anyopaque = null,
    policy: *tls.Policy,
    establishment: Signal,
    stopped: Signal,
    cancelled: std.atomic.Value(bool) = .init(false),
    connected: std.atomic.Value(bool) = .init(false),
    connect_busy: std.atomic.Value(bool) = .init(false),
    read_busy: std.atomic.Value(bool) = .init(false),
    write_busy: std.atomic.Value(bool) = .init(false),
    terminal: std.atomic.Value(u8) = .init(0), // 0 pending, 1 ready, 2 failed, 3 TLS, 4 cancelled
    signalled: bool = false, // confined to native serial callback queue
    read_eof: bool = false, // confined to the sole read caller
    timeout_ms: u32,
    maximum_io: usize = 64 * 1024 * 1024,

    pub fn create(allocator: std.mem.Allocator, host: []const u8, port: u16, config: tls.Config, timeout_ms: u32) !*Transport {
        if (port == 0 or host.len == 0 or host.len > 4096 or std.mem.indexOfScalar(u8, host, 0) != null) return error.InvalidConfiguration;
        const name = try allocator.dupeSentinel(u8, host, 0);
        defer allocator.free(name);
        const policy = try tls.Policy.create(std.heap.c_allocator, host, config);
        errdefer policy.release();
        const established = try Signal.init();
        errdefer established.deinit();
        const stopped = try Signal.init();
        errdefer stopped.deinit();
        const self = try allocator.create(Transport);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .policy = policy, .establishment = established, .stopped = stopped, .timeout_ms = timeout_ms };
        var port_buffer: [6]u8 = undefined;
        const port_text = try std.fmt.bufPrint(port_buffer[0..5], "{d}", .{port});
        port_buffer[port_text.len] = 0;
        const port_string = port_buffer[0..port_text.len :0];
        const verify: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) c_int = if (config.kind == .tcp or config.kind == .system) null else tls.Policy.verify;
        self.native = spice_nw_create(name.ptr, port_string.ptr, @intFromBool(config.kind != .tcp), policy.server_name.ptr, stateChanged, self, verify, policy.retain(), tls.Policy.releaseCallback) orelse return error.ConnectionFailed;
        spice_nw_start(self.native.?);
        return self;
    }
    pub fn connect(self: *Transport) Error!void {
        if (self.connect_busy.swap(true, .acq_rel)) return error.InvalidState;
        defer self.connect_busy.store(false, .release);
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        if (self.connected.load(.acquire)) return self.ready();
        switch (self.terminal.load(.acquire)) {
            1 => {
                self.connected.store(true, .release);
                return;
            },
            2 => return error.ConnectionFailed,
            3 => return error.TLSFailure,
            4 => return error.Cancelled,
            else => {},
        }
        const deadline = dispatch_time(0, @as(i64, self.timeout_ms) * 1_000_000);
        if (!self.establishment.wait(deadline)) {
            self.cancel();
            return error.Timeout;
        }
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        switch (self.terminal.load(.acquire)) {
            1 => self.connected.store(true, .release),
            3 => return error.TLSFailure,
            4 => return error.Cancelled,
            else => return error.ConnectionFailed,
        }
    }
    pub fn cancel(self: *Transport) void {
        if (!self.cancelled.swap(true, .acq_rel)) spice_nw_cancel(self.native.?);
    }
    pub fn destroy(self: *Transport) void {
        std.debug.assert(!self.connect_busy.load(.acquire) and !self.read_busy.load(.acquire) and !self.write_busy.load(.acquire));
        self.cancel();
        _ = self.stopped.wait(forever);
        spice_nw_destroy(self.native.?);
        self.native = null;
        self.establishment.deinit();
        self.stopped.deinit();
        self.policy.release();
        self.allocator.destroy(self);
    }
    fn ready(self: *Transport) Error!void {
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        if (!self.connected.load(.acquire)) return error.ConnectionClosed;
        switch (self.terminal.load(.acquire)) {
            3 => return error.TLSFailure,
            2, 4 => return error.ConnectionClosed,
            else => {},
        }
    }
    pub fn read(self: *Transport, buffer: []u8, minimum: usize) Error!usize {
        if (self.read_busy.swap(true, .acq_rel)) return error.InvalidState;
        defer self.read_busy.store(false, .release);
        return self.readUnlocked(buffer, minimum);
    }
    fn readUnlocked(self: *Transport, buffer: []u8, minimum: usize) Error!usize {
        try self.ready();
        if (buffer.len == 0 or minimum > buffer.len) return error.InvalidReadBounds;
        if (buffer.len > self.maximum_io or buffer.len > std.math.maxInt(u32)) return error.MessageTooLarge;
        if (self.read_eof) return error.ConnectionClosed;
        var operation = try Operation.init();
        defer operation.signal.deinit();
        operation.arm();
        spice_nw_read(self.native.?, buffer.ptr, @intCast(minimum), @intCast(buffer.len), Operation.complete, &operation);
        _ = operation.signal.wait(forever);
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        if (operation.domain != 0) return if (self.policy.kind == .tcp) error.ConnectionFailed else error.TLSFailure;
        self.read_eof = operation.eof;
        if (operation.size == 0 and operation.eof) return error.ConnectionClosed;
        return operation.size;
    }
    pub fn readExactly(self: *Transport, buffer: []u8) Error!void {
        if (self.read_busy.swap(true, .acq_rel)) return error.InvalidState;
        defer self.read_busy.store(false, .release);
        if (buffer.len > self.maximum_io) return error.MessageTooLarge;
        var position: usize = 0;
        while (position < buffer.len) {
            const size = try self.readUnlocked(buffer[position..], 1);
            if (size == 0) return error.ConnectionClosed;
            position += size;
        }
    }
    pub fn write(self: *Transport, bytes: []const u8) Error!void {
        if (self.write_busy.swap(true, .acq_rel)) return error.InvalidState;
        defer self.write_busy.store(false, .release);
        try self.ready();
        if (bytes.len > self.maximum_io) return error.MessageTooLarge;
        if (bytes.len == 0) return;
        var operation = try Operation.init();
        defer operation.signal.deinit();
        operation.arm();
        if (spice_nw_write(self.native.?, bytes.ptr, bytes.len, Operation.complete, &operation) == 0) {
            dispatch_release(operation.signal.handle);
            return error.OutOfMemory;
        }
        _ = operation.signal.wait(forever);
        if (self.cancelled.load(.acquire)) return error.Cancelled;
        if (operation.domain != 0) return if (self.policy.kind == .tcp) error.ConnectionFailed else error.TLSFailure;
    }
    fn stateChanged(context: ?*anyopaque, state: c_int, domain: c_int, code: c_int) callconv(.c) void {
        const self: *Transport = @ptrCast(@alignCast(context.?));
        // Network.framework error domain 3 is TLS. Terminal waiting TLS errors
        // must fail immediately; errSSLWouldBlock (-9803) remains nonterminal.
        const outcome: u8 = switch (state) {
            3 => 1,
            4 => if (domain == 3) 3 else 2,
            5 => 4,
            1 => if (domain == 3 and terminalTLS(code)) 3 else 0,
            else => 0,
        };
        if (outcome != 0) {
            self.terminal.store(outcome, .release);
            if (!self.signalled) {
                self.signalled = true;
                self.establishment.wake();
            }
        }
        if (state == 5) self.stopped.wake();
    }
};

// Exact terminal trust statuses from the existing NetworkSpiceTransport policy.
pub fn terminalTLS(code: c_int) bool {
    return switch (code) {
        -9807, -9808, -9812, -9813, -9814, -9815, -9825, -9826, -9827, -9828, -9829, -9831, -9843, -9862, -9863, -9884, -9885, -9886 => true,
        else => false,
    };
}
