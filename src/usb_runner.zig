//! Joined USB host executor. The embedding application explicitly enables one
//! channel and feeds ordered Desktop events. Same-guest migration preserves the
//! native protocol/device state; a different guest stops and closes it. Opening
//! a device always requires a separate exact attach request. There is no replay
//! after an uncertain send or automatic attachment to a replacement guest.
//!
//! Runtime is borrowed until destroy. All backend calls run on one worker.
//! attach/detach wait for their queued command: call them off the event-reader
//! thread so observations continue during a transport handoff. stop interrupts
//! blocked sends; destroy joins native cleanup, including reaping USB transfers.
const std = @import("std");
const sync = @import("sync.zig");
const cancel = @import("cancel.zig");
const bytes = @import("bytes.zig");
const native = @import("usb_host.zig");
extern "c" fn pthread_cond_timedwait_relative_np(*std.c.pthread_cond_t, *std.c.pthread_mutex_t, *const std.c.timespec) std.c.E;
pub const Options = struct { channel_id: u8 = 0, host: native.Options = .{}, maximum_queued_bytes: usize = 16 * 1024 * 1024 };
pub const Statistics = struct { received_bytes: u64 = 0, sent_bytes: u64 = 0, sent_packets: u64 = 0, queued_bytes: usize = 0 };
pub fn Runner(comptime Runtime: type, comptime Backend: type) type {
    return struct {
        const Self = @This();
        const Request = struct { device: ?struct { bus: u8, address: u8 }, flush_only: bool = false, done: bool = false, failure: ?anyerror = null, backend_code: c_int = 0 };
        const Command = union(enum) { guest: bytes.Slice, request: *Request };
        allocator: std.mem.Allocator,
        runtime: *Runtime,
        options: Options,
        host: *Backend,
        mutex: sync.Mutex = .{},
        changed: sync.Condition = .{},
        token: cancel.Token = .{},
        thread: ?std.Thread = null,
        generation: u64 = 0,
        lifecycle: u64 = 0,
        stopping: bool = false,
        finished: bool = false,
        failure: ?anyerror = null,
        backend_code: c_int = 0,
        commands: [64]Command = undefined,
        head: usize = 0,
        count: usize = 0,
        stats: Statistics = .{},
        pub fn create(a: std.mem.Allocator, runtime: *Runtime, options: Options) !*Self {
            try options.host.validate();
            if (options.host.maximum_packet_bytes > 1024 * 1024 or options.maximum_queued_bytes == 0 or options.maximum_queued_bytes > 64 * 1024 * 1024) return error.InvalidArgument;
            const host = try Backend.create(a, options.host);
            errdefer host.destroy();
            return createWithBackend(a, runtime, options, host);
        }
        /// Takes the backend only on success. It is destroyed on worker exit.
        pub fn createWithBackend(a: std.mem.Allocator, runtime: *Runtime, options: Options, host: *Backend) !*Self {
            try options.host.validate();
            if (options.host.maximum_packet_bytes > 1024 * 1024 or options.maximum_queued_bytes == 0 or options.maximum_queued_bytes > 64 * 1024 * 1024) return error.InvalidArgument;
            const self = try a.create(Self);
            errdefer a.destroy(self);
            self.* = .{ .allocator = a, .runtime = runtime, .options = options, .host = host };
            errdefer {
                self.token.deinit();
                self.changed.deinit();
                self.mutex.deinit();
            }
            self.thread = try std.Thread.spawn(.{}, run, .{self});
            return self;
        }
        fn stopLocked(self: *Self, failure: ?anyerror) void {
            if (self.stopping) return;
            self.stopping = true;
            self.failure = failure;
            self.token.cancel();
            self.changed.broadcast();
        }
        pub fn stop(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.stopLocked(null);
        }
        pub fn join(self: *Self) void {
            if (self.thread) |thread| thread.join();
            self.thread = null;
        }
        /// Exclusive with all other callers, after joining attach/detach calls.
        pub fn destroy(self: *Self) void {
            self.stop();
            self.join();
            self.token.deinit();
            self.changed.deinit();
            self.mutex.deinit();
            self.allocator.destroy(self);
        }
        pub fn status(self: *Self) struct { finished: bool, failure: ?anyerror, backend_code: c_int } {
            self.mutex.lock();
            defer self.mutex.unlock();
            return .{ .finished = self.finished, .failure = self.failure, .backend_code = self.backend_code };
        }
        pub fn statistics(self: *Self) Statistics {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.stats;
        }
        pub fn observe(self: *Self, event: Runtime.Event) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.stopping) return error.Closed;
            if (event.lifecycle < self.lifecycle or event.generation < self.generation) return;
            if (self.lifecycle != 0 and event.lifecycle != self.lifecycle) {
                self.stopLocked(null);
                return;
            }
            self.lifecycle = event.lifecycle;
            self.generation = event.generation;
            self.changed.broadcast();
            switch (event.value) {
                .disconnected, .failed => self.stopLocked(null),
                .child => |child| switch (child) {
                    .usb => |data| {
                        if (event.key.id != self.options.channel_id) return;
                        const weight = data.retainedBytes();
                        if (self.count == self.commands.len or weight > self.options.maximum_queued_bytes - self.stats.queued_bytes) {
                            self.stopLocked(error.USBQueueLimit);
                            return error.USBQueueLimit;
                        }
                        self.commands[(self.head + self.count) % self.commands.len] = .{ .guest = data.clone() };
                        self.count += 1;
                        self.stats.queued_bytes += weight;
                    },
                    else => {},
                },
                else => {},
            }
        }
        /// Errors from the explicit operation return to its caller; worker I/O
        /// errors are available through status. Native integer errors are copied
        /// to the optional output rather than lost during error translation.
        pub fn device(self: *Self, selected: ?struct { bus: u8, address: u8 }, code: ?*c_int) !void {
            if (code) |out| out.* = 0;
            return self.submitRequest(.{ .device = if (selected) |v| .{ .bus = v.bus, .address = v.address } else null }, code);
        }
        pub fn ready(self: *Self) !void {
            return self.submitRequest(.{ .device = null, .flush_only = true }, null);
        }
        fn submitRequest(self: *Self, value: Request, code: ?*c_int) !void {
            var request = value;
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.stopping) return error.Closed;
            if (self.lifecycle == 0) return error.USBNotReady;
            if (self.count == self.commands.len) return error.USBQueueLimit;
            self.commands[(self.head + self.count) % self.commands.len] = .{ .request = &request };
            self.count += 1;
            self.changed.broadcast();
            while (!request.done) self.changed.wait(&self.mutex);
            if (code) |out| out.* = request.backend_code;
            if (request.failure) |err| return err;
        }
        fn pauseLocked(self: *Self) void {
            const duration: std.c.timespec = .{ .sec = 0, .nsec = 10 * 1000 * 1000 };
            const result = pthread_cond_timedwait_relative_np(&self.changed.value, &self.mutex.value, &duration);
            std.debug.assert(result == .SUCCESS or result == .TIMEDOUT);
        }
        fn flush(self: *Self, lifecycle: u64) !void {
            while (self.host.outputSize() != 0) {
                const packet = self.host.peekOutput();
                self.runtime.sendUSBAt(self.options.channel_id, lifecycle, packet, &self.token) catch |err| {
                    if (err != error.USBHandoffPending) return err;
                    // No bytes entered the transport. Preserve this exact packet
                    // until handoff is ready; stop still cancels the wait.
                    self.mutex.lock();
                    if (!self.stopping) self.pauseLocked();
                    self.mutex.unlock();
                    try self.token.check();
                    continue;
                };
                self.host.consumeOutput(packet.len);
                self.mutex.lock();
                self.stats.sent_bytes +|= packet.len;
                self.stats.sent_packets +|= 1;
                self.mutex.unlock();
            }
        }
        fn finishRequest(self: *Self, request: *Request, failure: ?anyerror) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            request.failure = failure;
            request.backend_code = if (failure) |err| (if (err == error.USBBackendFailure) self.host.backend_code else 0) else 0;
            request.done = true;
            self.changed.broadcast();
        }
        fn loop(self: *Self) !void {
            while (true) {
                self.mutex.lock();
                while (!self.stopping and self.lifecycle == 0) self.changed.wait(&self.mutex);
                if (self.stopping) {
                    self.mutex.unlock();
                    return;
                }
                const lifecycle = self.lifecycle;
                const command: ?Command = if (self.count == 0) null else self.commands[self.head];
                if (command != null) {
                    self.head = (self.head + 1) % self.commands.len;
                    self.count -= 1;
                }
                self.mutex.unlock();
                if (command) |value| switch (value) {
                    .guest => |data| {
                        defer data.release();
                        defer {
                            self.mutex.lock();
                            self.stats.queued_bytes -= data.retainedBytes();
                            self.mutex.unlock();
                        }
                        try self.token.check();
                        try self.host.receive(data.bytes());
                        self.mutex.lock();
                        self.stats.received_bytes +|= data.bytes().len;
                        self.mutex.unlock();
                    },
                    .request => |request| {
                        self.token.check() catch |err| {
                            self.finishRequest(request, err);
                            return err;
                        };
                        const result = if (request.flush_only) {} else if (request.device) |v| self.host.attach(v.bus, v.address) else self.host.detach();
                        if (result) |_| {} else |err| {
                            self.finishRequest(request, err);
                            // An explicit selection error is reported only to the
                            // requesting caller; no selected replacement is tried.
                            continue;
                        }
                        self.flush(lifecycle) catch |err| {
                            self.finishRequest(request, err);
                            return err;
                        };
                        self.finishRequest(request, null);
                    },
                };
                try self.token.check();
                try self.host.pump(0);
                try self.flush(lifecycle);
                self.mutex.lock();
                if (self.count == 0 and !self.stopping) self.pauseLocked();
                self.mutex.unlock();
            }
        }
        fn run(self: *Self) void {
            const result = self.loop();
            self.mutex.lock();
            if (result) |_| {} else |err| {
                if (!self.stopping) self.stopLocked(err);
            }
            self.backend_code = self.host.backend_code;
            self.stopping = true;
            for (0..self.count) |i| switch (self.commands[(self.head + i) % self.commands.len]) {
                .guest => |data| data.release(),
                .request => |request| {
                    request.failure = error.Cancelled;
                    request.done = true;
                },
            };
            self.count = 0;
            self.stats.queued_bytes = 0;
            self.changed.broadcast();
            self.mutex.unlock();
            self.host.destroy();
            self.mutex.lock();
            self.finished = true;
            self.changed.broadcast();
            self.mutex.unlock();
        }
    };
}
