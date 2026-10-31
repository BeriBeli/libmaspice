const std = @import("std");
const t = std.testing;
const s = @import("spice");
const a = t.allocator;
extern "c" fn pthread_cond_timedwait_relative_np(*std.c.pthread_cond_t, *std.c.pthread_mutex_t, *const std.c.timespec) std.c.E;
const Runtime = struct {
    pub const Event = struct { lifecycle: u64 = 1, generation: u64 = 1, key: struct { id: u8 = 0 } = .{}, value: union(enum) { connected, disconnected, failed: anyerror, migration, child: union(enum) { usb: s.bytes.Slice, other }, other } };
    mutex: s.sync.Mutex = .{},
    changed: s.sync.Condition = .{},
    block: bool = false,
    pending: bool = false,
    fail: bool = false,
    entered: usize = 0,
    sent: usize = 0,
    output: [2048]u8 = undefined,
    fn deinit(self: *Runtime) void {
        self.changed.deinit();
        self.mutex.deinit();
    }
    fn wake(raw: *anyopaque) void {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        self.changed.broadcast();
        self.mutex.unlock();
    }
    fn wait(self: *Runtime, field: enum { entered, sent }, count: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while ((if (field == .entered) self.entered else self.sent) < count) {
            const duration: std.c.timespec = .{ .sec = 5, .nsec = 0 };
            if (pthread_cond_timedwait_relative_np(&self.changed.value, &self.mutex.value, &duration) != .SUCCESS) return error.Timeout;
        }
    }
    fn release(self: *Runtime) void {
        self.mutex.lock();
        self.block = false;
        self.pending = false;
        self.changed.broadcast();
        self.mutex.unlock();
    }
    pub fn sendUSBAt(self: *Runtime, _: u8, lifecycle: u64, data: []const u8, token: *s.cancel.Token) !void {
        try t.expectEqual(@as(u64, 1), lifecycle);
        var registration: s.cancel.Registration = .{ .context = self, .wake = wake };
        token.register(&registration);
        defer token.unregister(&registration);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.entered += 1;
        self.changed.broadcast();
        while (self.block) {
            try token.check();
            self.changed.wait(&self.mutex);
        }
        try token.check();
        if (self.pending) return error.USBHandoffPending;
        if (self.fail) return error.InjectedWriteFailure;
        if (data.len > self.output.len - self.sent) return error.TestOverflow;
        @memcpy(self.output[self.sent..][0..data.len], data);
        self.sent += data.len;
        self.changed.broadcast();
    }
};
const Backend = struct {
    allocator: std.mem.Allocator,
    options: s.usb_host.Options,
    output: [1024]u8 = undefined,
    count: usize = 2,
    backend_code: c_int = 0,
    pub fn create(allocator: std.mem.Allocator, options: s.usb_host.Options) !*Backend {
        const self = try allocator.create(Backend);
        self.* = .{ .allocator = allocator, .options = options };
        @memcpy(self.output[0..2], "HI");
        return self;
    }
    pub fn destroy(self: *Backend) void {
        self.allocator.destroy(self);
    }
    pub fn outputSize(self: *Backend) usize {
        return self.count;
    }
    pub fn peekOutput(self: *Backend) []const u8 {
        return self.output[0..@min(self.count, self.options.maximum_packet_bytes)];
    }
    pub fn consumeOutput(self: *Backend, count: usize) void {
        std.mem.copyForwards(u8, self.output[0 .. self.count - count], self.output[count..self.count]);
        self.count -= count;
    }
    pub fn receive(self: *Backend, data: []const u8) !void {
        if (data.len > self.output.len - self.count) return error.TestOverflow;
        @memcpy(self.output[self.count..][0..data.len], data);
        self.count += data.len;
    }
    pub fn pump(_: *Backend, _: u32) !void {}
    pub fn attach(self: *Backend, bus: u8, address: u8) !void {
        if (bus == 255) return error.USBDeviceNotFound;
        if (bus == 254) {
            self.backend_code = -77;
            return error.USBBackendFailure;
        }
        try self.receive(&.{ bus, address });
    }
    pub fn detach(self: *Backend) !void {
        try self.receive("D");
    }
};
const Runner = s.usb_runner.Runner(Runtime, Backend);
fn receive(runner: *Runner, data: []const u8, generation: u64) !void {
    const payload = try s.bytes.Slice.copy(a, data);
    defer payload.release();
    try runner.observe(.{ .generation = generation, .value = .{ .child = .{ .usb = payload } } });
}
test "USB serial bytes commands errors and same-guest migration preserve order" {
    var runtime: Runtime = .{};
    defer runtime.deinit();
    const runner = try Runner.create(a, &runtime, .{ .host = .{ .maximum_packet_bytes = 1 } });
    defer runner.destroy();
    try t.expectError(error.USBNotReady, runner.device(.{ .bus = 1, .address = 2 }, null));
    try runner.observe(.{ .value = .connected });
    try runtime.wait(.sent, 2);
    try receive(runner, "abc", 1);
    try runtime.wait(.sent, 5);
    try runner.observe(.{ .generation = 2, .value = .migration });
    try receive(runner, "d", 2);
    try runtime.wait(.sent, 6);
    try receive(runner, "OLD", 1);
    try t.expectError(error.USBDeviceNotFound, runner.device(.{ .bus = 255, .address = 255 }, null));
    var code: c_int = 0;
    try t.expectError(error.USBBackendFailure, runner.device(.{ .bus = 254, .address = 1 }, &code));
    try t.expectEqual(@as(c_int, -77), code);
    try runner.device(.{ .bus = 'E', .address = 'F' }, null);
    try runner.device(null, null);
    try runtime.wait(.sent, 9);
    runner.stop();
    runner.join();
    try t.expectEqualStrings("HIabcdEFD", runtime.output[0..runtime.sent]);
    try t.expectEqual(@as(u64, 4), runner.statistics().received_bytes);
    try t.expectEqual(@as(usize, 0), runner.statistics().queued_bytes);
    try t.expect(runner.status().finished and runner.status().failure == null);
}
test "USB handoff before entering wire defers exact packet without consuming or replaying" {
    var runtime: Runtime = .{ .pending = true };
    defer runtime.deinit();
    const runner = try Runner.create(a, &runtime, .{});
    defer runner.destroy();
    try runner.observe(.{ .value = .connected });
    try runtime.wait(.entered, 1);
    try receive(runner, "after", 1);
    runtime.release();
    try runner.observe(.{ .generation = 2, .value = .migration });
    try runtime.wait(.sent, 7);
    runner.stop();
    runner.join();
    try t.expectEqualStrings("HIafter", runtime.output[0..runtime.sent]);
}
test "USB guest change and stop cancel blocked sends and drain queued input" {
    for ([_]bool{ false, true }) |switch_guest| {
        var runtime: Runtime = .{ .block = true };
        defer runtime.deinit();
        const runner = try Runner.create(a, &runtime, .{});
        defer runner.destroy();
        try runner.observe(.{ .value = .connected });
        try runtime.wait(.entered, 1);
        try receive(runner, "queued", 1);
        if (switch_guest) try runner.observe(.{ .generation = 2, .lifecycle = 2, .value = .connected }) else runner.stop();
        runner.join();
        try t.expect(runner.status().finished and runner.status().failure == null);
        try t.expectEqual(@as(usize, 0), runner.statistics().queued_bytes);
        try t.expectEqual(@as(usize, 0), runtime.sent);
    }
}
test "USB bounded observation queue stops worker and preserves allocation ownership" {
    var runtime: Runtime = .{ .block = true };
    defer runtime.deinit();
    const runner = try Runner.create(a, &runtime, .{ .maximum_queued_bytes = 2 });
    defer runner.destroy();
    try runner.observe(.{ .value = .connected });
    try runtime.wait(.entered, 1);
    try receive(runner, "ab", 1);
    try t.expectError(error.USBQueueLimit, receive(runner, "c", 1));
    runner.join();
    try t.expectEqual(error.USBQueueLimit, runner.status().failure.?);
    try t.expectEqual(@as(usize, 0), runner.statistics().queued_bytes);
}
test "USB failed entered send terminates without replay" {
    var runtime: Runtime = .{ .fail = true };
    defer runtime.deinit();
    const runner = try Runner.create(a, &runtime, .{});
    defer runner.destroy();
    try runner.observe(.{ .value = .connected });
    try runtime.wait(.entered, 1);
    runner.join();
    try t.expectEqual(error.InjectedWriteFailure, runner.status().failure.?);
    try t.expectEqual(@as(usize, 1), runtime.entered);
    try t.expectEqual(@as(usize, 0), runtime.sent);
}
fn allocationCase(allocator: std.mem.Allocator) !void {
    var runtime: Runtime = .{};
    defer runtime.deinit();
    const runner = try Runner.create(allocator, &runtime, .{});
    defer runner.destroy();
}
test "USB runner allocation failures release all joined owners" {
    try t.checkAllAllocationFailures(a, allocationCase, .{});
}
const DeviceCall = struct {
    runner: *Runner,
    failure: ?anyerror = null,
    fn run(self: *DeviceCall) void {
        self.runner.device(.{ .bus = 1, .address = 2 }, null) catch |err| {
            self.failure = err;
        };
    }
};
test "USB stop releases an explicit device caller waiting on a blocked send" {
    var runtime: Runtime = .{};
    defer runtime.deinit();
    const runner = try Runner.create(a, &runtime, .{});
    defer runner.destroy();
    try runner.observe(.{ .value = .connected });
    try runtime.wait(.sent, 2);
    runtime.mutex.lock();
    runtime.block = true;
    runtime.mutex.unlock();
    var call: DeviceCall = .{ .runner = runner };
    const thread = try std.Thread.spawn(.{}, DeviceCall.run, .{&call});
    var joined = false;
    defer if (!joined) {
        runner.stop();
        thread.join();
    };
    try runtime.wait(.entered, 2);
    runner.stop();
    runner.join();
    thread.join();
    joined = true;
    try t.expectEqual(error.Cancelled, call.failure.?);
    runtime.mutex.lock();
    const sent = runtime.sent;
    runtime.mutex.unlock();
    try t.expectEqual(@as(usize, 2), sent);
}

test "shared USB host staged packet survives external drain and caller release" {
    const HostABI = s.usb_host_abi;
    var host: ?*HostABI.Host = null;
    try t.expectEqual(@as(c_int, 0), HostABI.spice_zig_usb_host_create(&.{ .maximum_buffered_bytes = 4096, .maximum_packet_bytes = 8 }, &host));
    var owned = true;
    defer if (owned) HostABI.spice_zig_usb_host_destroy(host);
    const backend = try s.usb_shared_backend.Backend.createExisting(a, host.?);
    defer backend.destroy();
    try t.expectEqual(@as(usize, 8), backend.outputSize());
    var first: [8]u8 = undefined;
    @memcpy(&first, backend.peekOutput());
    var packets: ?*HostABI.Packets = null;
    try t.expectEqual(@as(c_int, 0), HostABI.spice_zig_usb_host_exchange(host, 0, null, 0, 0, 0, 0, &packets, null));
    defer HostABI.spice_zig_usb_packets_destroy(packets);
    try t.expectEqual(@as(usize, 72), packets.?.data.len);
    HostABI.spice_zig_usb_host_destroy(host);
    owned = false;
    try t.expectEqualSlices(u8, &first, backend.peekOutput());
    backend.consumeOutput(8);
    try t.expectEqual(@as(usize, 0), backend.outputSize());
    try backend.pump(0);
}

test "shared USB runner owns the original native host through a blocked send and cancellation" {
    const HostABI = s.usb_host_abi;
    var host: ?*HostABI.Host = null;
    try t.expectEqual(@as(c_int, 0), HostABI.spice_zig_usb_host_create(&.{ .maximum_buffered_bytes = 4096, .maximum_packet_bytes = 8 }, &host));
    const backend = try s.usb_shared_backend.Backend.createExisting(a, host.?);
    HostABI.spice_zig_usb_host_destroy(host);
    var runtime: Runtime = .{ .block = true };
    defer runtime.deinit();
    const SharedRunner = s.usb_runner.Runner(Runtime, s.usb_shared_backend.Backend);
    const runner = SharedRunner.createWithBackend(a, &runtime, .{}, backend) catch |err| {
        backend.abandon();
        return err;
    };
    defer runner.destroy();
    try runner.observe(.{ .value = .connected });
    try runtime.wait(.entered, 1);
    runner.stop();
    runner.join();
    try t.expect(runner.status().finished);
    try t.expectEqual(@as(usize, 0), runtime.sent);
}
