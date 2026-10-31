const std = @import("std");
const t = std.testing;
const a = t.allocator;
const s = @import("spice");
const sync = s.sync;
const cancel = s.cancel;
extern "c" fn pthread_cond_timedwait_relative_np(*std.c.pthread_cond_t, *std.c.pthread_mutex_t, *const std.c.timespec) std.c.E;
const Harness = struct {
    mutex: sync.Mutex = .{},
    changed: sync.Condition = .{},
    block_fs: bool = false,
    block_send: bool = false,
    fail_send: bool = false,
    fs_entered: [10]usize = @splat(0),
    send_entered: [10]usize = @splat(0),
    delivered: [10]usize = @splat(0),
    active_fs: usize = 0,
    peak_fs: usize = 0,
    chunks: [8]usize = @splat(0),
    count: usize = 0,
    transport_generation: u64 = 1,
    fn deinit(self: *Harness) void {
        self.changed.deinit();
        self.mutex.deinit();
    }
    fn unblock(self: *Harness) void {
        self.mutex.lock();
        self.block_fs = false;
        self.block_send = false;
        self.changed.broadcast();
        self.mutex.unlock();
    }
    fn wait(self: *Harness, field: enum { fs_entered, send_entered, delivered }, index: usize, expected: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (switch (field) {
            .fs_entered => self.fs_entered[index],
            .send_entered => self.send_entered[index],
            .delivered => self.delivered[index],
        } < expected) {
            const deadline: std.c.timespec = .{ .sec = 5, .nsec = 0 };
            if (pthread_cond_timedwait_relative_np(&self.changed.value, &self.mutex.value, &deadline) != .SUCCESS) return error.Timeout;
        }
    }
    fn wake(raw: *anyopaque) void {
        const self: *Harness = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        self.changed.broadcast();
        self.mutex.unlock();
    }
};
const Filesystem = struct {
    state: *Harness,
    pub fn execute(self: *const Filesystem, request: s.webdav_http.Request) ![]u8 {
        const index: usize = request.target[1] - '0';
        self.state.mutex.lock();
        self.state.active_fs += 1;
        self.state.peak_fs = @max(self.state.peak_fs, self.state.active_fs);
        self.state.fs_entered[index] += 1;
        self.state.changed.broadcast();
        while (index <= 2 and self.state.block_fs) self.state.changed.wait(&self.state.mutex);
        self.state.active_fs -= 1;
        self.state.mutex.unlock();
        const size: usize = if (index == 8) 70000 else if (index == 9) 0 else 1;
        const bytes = try a.alloc(u8, size);
        @memset(bytes, @intCast(index));
        return bytes;
    }
};
const Runtime = struct {
    pub const Event = struct { lifecycle: u64 = 1, generation: u64 = 1, key: struct { id: u8 = 0 } = .{}, value: union(enum) { connected, disconnected, failed: anyerror, migration, child: union(enum) { webdav: s.webdav.Event, other }, other } };
    state: *Harness,
    pub fn sendWebDAVAt(self: *Runtime, _: u8, generation: u64, client: i64, bytes: []const u8, token: *cancel.Token) !void {
        const index: usize = @intCast(client);
        var registration: cancel.Registration = .{ .context = self.state, .wake = Harness.wake };
        token.register(&registration);
        defer token.unregister(&registration);
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        self.state.send_entered[index] += 1;
        self.state.changed.broadcast();
        while (client == 1 and self.state.block_send) {
            try token.check();
            self.state.changed.wait(&self.state.mutex);
        }
        try token.check();
        if (generation != self.state.transport_generation) return error.StaleWebDAVGeneration;
        if (self.state.fail_send) return error.InjectedSendFailure;
        self.state.delivered[index] += 1;
        if (self.state.count < self.state.chunks.len) {
            self.state.chunks[self.state.count] = bytes.len;
            self.state.count += 1;
        }
        self.state.changed.broadcast();
    }
};
const Runner = s.webdav_runner.Runner(Runtime, Filesystem);
fn submit(runner: *Runner, client: i64, bytes: []const u8, generation: u64) !void {
    return submitAt(runner, client, bytes, generation, 1);
}
fn submitAt(runner: *Runner, client: i64, bytes: []const u8, generation: u64, lifecycle: u64) !void {
    const slice = try s.bytes.Slice.copy(a, bytes);
    defer slice.release();
    try runner.observe(.{ .lifecycle = lifecycle, .generation = generation, .value = .{ .child = .{ .webdav = .{ .request = .{ .client = client, .data = slice } } } } });
}
fn close(runner: *Runner, client: i64) !void {
    try runner.observe(.{ .value = .{ .child = .{ .webdav = .{ .closed = client } } } });
}
extern "c" fn usleep(c_uint) c_int;
fn finished(runner: *Runner) !void {
    for (0..5000) |_| {
        if (runner.status().finished) return;
        _ = usleep(1000);
    }
    return error.Timeout;
}
fn options(parallelism: usize) s.webdav_runner.Options {
    return .{ .filesystem_parallelism = parallelism, .limits = .{ .jobs = 4, .http = .{ .body_bytes = 100000 } } };
}
test "WebDAV blocked sends release filesystem permits and retain same-client FIFO" {
    var state: Harness = .{ .block_send = true };
    defer state.deinit();
    var runtime: Runtime = .{ .state = &state };
    const fs: Filesystem = .{ .state = &state };
    const runner = try Runner.create(a, &runtime, &fs, options(1));
    defer runner.destroy();
    defer state.unblock();
    try submit(runner, 1, "GET /1 HTTP/1.1\r\n\r\nPUT /3 HTTP/1.1\r\n\r\n", 1);
    try state.wait(.send_entered, 1, 1);
    try submit(runner, 2, "GET /2 HTTP/1.1\r\n\r\n", 1);
    try state.wait(.delivered, 2, 1);
    state.mutex.lock();
    const later = state.fs_entered[3];
    const peak = state.peak_fs;
    state.mutex.unlock();
    try t.expectEqual(0, later);
    try t.expectEqual(1, peak);
    state.unblock();
    try state.wait(.delivered, 1, 2);
}
test "WebDAV filesystem parallelism is bounded and close reuse waits for retired mutation" {
    var state: Harness = .{ .block_fs = true };
    defer state.deinit();
    var runtime: Runtime = .{ .state = &state };
    const fs: Filesystem = .{ .state = &state };
    const runner = try Runner.create(a, &runtime, &fs, options(2));
    defer runner.destroy();
    defer state.unblock();
    try submit(runner, 1, "GET /1 HTTP/1.1\r\n\r\n", 1);
    try submit(runner, 2, "GET /2 HTTP/1.1\r\n\r\n", 1);
    try state.wait(.fs_entered, 1, 1);
    try state.wait(.fs_entered, 2, 1);
    try close(runner, 1);
    try submit(runner, 1, "PUT /3 HTTP/1.1\r\n\r\n", 1);
    try submit(runner, 4, "GET /4 HTTP/1.1\r\n\r\n", 1);
    state.mutex.lock();
    const peak = state.peak_fs;
    const later = state.fs_entered[3];
    state.mutex.unlock();
    try t.expectEqual(2, peak);
    try t.expectEqual(0, later);
    state.unblock();
    try state.wait(.delivered, 1, 1);
    try state.wait(.delivered, 2, 1);
    try state.wait(.delivered, 4, 1);
    try t.expectEqual(1, runner.diagnostics().discarded);
    state.mutex.lock();
    const actual_peak = state.peak_fs;
    state.mutex.unlock();
    try t.expectEqual(2, actual_peak);
}
test "WebDAV active send cancellation permits same-ID reuse without acknowledging old response" {
    var state: Harness = .{ .block_send = true };
    defer state.deinit();
    var runtime: Runtime = .{ .state = &state };
    const fs: Filesystem = .{ .state = &state };
    const runner = try Runner.create(a, &runtime, &fs, options(2));
    defer runner.destroy();
    defer state.unblock();
    try submit(runner, 1, "GET /1 HTTP/1.1\r\n\r\nPUT /2 HTTP/1.1\r\n\r\n", 1);
    try state.wait(.send_entered, 1, 1);
    try close(runner, 1);
    try submit(runner, 1, "GET /3 HTTP/1.1\r\n\r\n", 1);
    try state.wait(.send_entered, 1, 2);
    state.mutex.lock();
    const old_delivered = state.delivered[1];
    const old_mutation = state.fs_entered[2];
    state.mutex.unlock();
    try t.expectEqual(0, old_delivered);
    try t.expectEqual(0, old_mutation);
    state.unblock();
    try state.wait(.delivered, 1, 1);
    try t.expect(runner.status().failure == null);
}
test "WebDAV guest switch retires filesystem result and ignores late events" {
    var state: Harness = .{ .block_fs = true };
    defer state.deinit();
    var runtime: Runtime = .{ .state = &state };
    const fs: Filesystem = .{ .state = &state };
    const runner = try Runner.create(a, &runtime, &fs, options(2));
    defer runner.destroy();
    defer state.unblock();
    try submit(runner, 1, "GET /1 HTTP/1.1\r\n\r\n", 1);
    try state.wait(.fs_entered, 1, 1);
    state.mutex.lock();
    state.transport_generation = 2;
    state.mutex.unlock();
    try runner.observe(.{ .lifecycle = 2, .generation = 2, .value = .connected });
    try submit(runner, 2, "PUT /2 HTTP/1.1\r\n\r\n", 1);
    try submitAt(runner, 3, "GET /3 HTTP/1.1\r\n\r\n", 2, 2);
    try state.wait(.delivered, 3, 1);
    state.unblock();
    runner.stop();
    // destroy joins before reading the harness below.
    try finished(runner);
    runner.join();
    try t.expectEqual(0, state.delivered[1]);
    try t.expectEqual(0, state.fs_entered[2]);
    try t.expectEqual(0, runner.diagnostics().retained());
    try t.expect(runner.status().finished);
}
test "WebDAV response chunks include exact 65535 boundary and empty close frame" {
    var state: Harness = .{};
    defer state.deinit();
    var runtime: Runtime = .{ .state = &state };
    const fs: Filesystem = .{ .state = &state };
    const runner = try Runner.create(a, &runtime, &fs, options(1));
    defer runner.destroy();
    try submit(runner, 1, "GET /8 HTTP/1.1\r\n\r\nGET /9 HTTP/1.1\r\n\r\n", 1);
    try state.wait(.delivered, 1, 3);
    state.mutex.lock();
    defer state.mutex.unlock();
    try t.expectEqualSlices(usize, &.{ 65535, 4465, 0 }, state.chunks[0..3]);
}
test "WebDAV failed response prevents later mutations and malformed admission is terminal" {
    var state: Harness = .{ .fail_send = true };
    defer state.deinit();
    var runtime: Runtime = .{ .state = &state };
    const fs: Filesystem = .{ .state = &state };
    const runner = try Runner.create(a, &runtime, &fs, options(2));
    defer runner.destroy();
    try submit(runner, 1, "GET /1 HTTP/1.1\r\n\r\nPUT /2 HTTP/1.1\r\n\r\n", 1);
    try state.wait(.send_entered, 1, 1);
    try finished(runner);
    runner.join();
    try t.expectEqual(error.InjectedSendFailure, runner.status().failure.?);
    try t.expectEqual(0, state.fs_entered[2]);
    const other = try Runner.create(a, &runtime, &fs, options(1));
    defer other.destroy();
    try t.expectError(error.InvalidRequest, submit(other, 1, "GET / HTTP/8\r\n\r\n", 1));
    try t.expectEqual(error.InvalidRequest, other.status().failure.?);
}
fn allocated(allocator: std.mem.Allocator) !void {
    var state: Harness = .{};
    defer state.deinit();
    var runtime: Runtime = .{ .state = &state };
    const fs: Filesystem = .{ .state = &state };
    const runner = try Runner.create(allocator, &runtime, &fs, .{ .filesystem_parallelism = 1, .limits = .{ .jobs = 1 } });
    defer runner.destroy();
}
test "WebDAV executor creation allocation failure and idle destruction release ownership" {
    try t.checkAllAllocationFailures(a, allocated, .{});
}
test "WebDAV same-guest migration retains HTTP prefix but fences previously admitted responses" {
    var state: Harness = .{ .block_fs = true };
    defer state.deinit();
    var runtime: Runtime = .{ .state = &state };
    const fs: Filesystem = .{ .state = &state };
    const runner = try Runner.create(a, &runtime, &fs, options(2));
    defer runner.destroy();
    defer state.unblock();
    try submit(runner, 1, "GET /1 HTTP/1.1\r\n\r\n", 1);
    try submit(runner, 2, "GET /", 1);
    try state.wait(.fs_entered, 1, 1);
    state.mutex.lock();
    state.transport_generation = 2;
    state.mutex.unlock();
    try runner.observe(.{ .generation = 2, .value = .migration });
    try submit(runner, 2, "3 HTTP/1.1\r\n\r\n", 2);
    try state.wait(.delivered, 2, 1);
    state.unblock();
    try state.wait(.send_entered, 1, 1);
    for (0..5000) |_| {
        if (runner.diagnostics().pending_jobs == 0) break;
        _ = usleep(1000);
    }
    try t.expectEqual(0, runner.diagnostics().pending_jobs);
    try t.expectEqual(1, runner.diagnostics().completed);
    try t.expectEqual(1, runner.diagnostics().cancelled);
    try t.expectEqual(null, runner.status().failure);
    state.mutex.lock();
    defer state.mutex.unlock();
    try t.expectEqual(0, state.delivered[1]);
}

test "WebDAV shared attachments keep response ownership and global filesystem limit" {
    var state: Harness = .{ .block_fs = true };
    defer state.deinit();
    var other: Harness = .{};
    defer other.deinit();
    var runtime: Runtime = .{ .state = &state };
    var runtime_other: Runtime = .{ .state = &other };
    const fs: Filesystem = .{ .state = &state };
    var shared = try s.webdav_runner.Shared.init(a, options(1));
    defer shared.deinit();
    const first = try Runner.createShared(a, &runtime, &fs, 0, &shared);
    defer first.destroy();
    const second = try Runner.createShared(a, &runtime_other, &fs, 0, &shared);
    defer second.destroy();
    defer state.unblock();
    try submit(first, 1, "GET /1 HTTP/1.1\r\n\r\n", 1);
    try state.wait(.fs_entered, 1, 1);
    try submit(second, 2, "GET /2 HTTP/1.1\r\n\r\n", 1);
    state.unblock();
    try state.wait(.delivered, 1, 1);
    try other.wait(.delivered, 2, 1);
    first.stop();
    first.join();
    // Closing an attachment clears client state but leaves the shared server
    // usable by other attachments and by later standalone calls.
    try submit(second, 3, "GET /3 HTTP/1.1\r\n\r\n", 1);
    try other.wait(.delivered, 3, 1);
    second.stop();
    second.join();
    try t.expectEqual(1, state.peak_fs);
    try t.expectEqual(0, state.delivered[2]);
    try t.expectEqual(0, other.delivered[1]);
    try t.expectEqual(0, shared.queue.diagnostics().retained());
}

test "WebDAV another attachment close cancels send and preserves same-client order" {
    var state: Harness = .{ .block_send = true };
    defer state.deinit();
    var other: Harness = .{};
    defer other.deinit();
    var runtime: Runtime = .{ .state = &state };
    var runtime_other: Runtime = .{ .state = &other };
    const fs: Filesystem = .{ .state = &state };
    var shared = try s.webdav_runner.Shared.init(a, options(2));
    defer shared.deinit();
    const first = try Runner.createShared(a, &runtime, &fs, 0, &shared);
    defer first.destroy();
    const second = try Runner.createShared(a, &runtime_other, &fs, 0, &shared);
    defer second.destroy();
    defer state.unblock();
    try submit(first, 1, "GET /1 HTTP/1.1\r\n\r\n", 1);
    try state.wait(.send_entered, 1, 1);
    try submit(second, 1, "PUT /3 HTTP/1.1\r\n\r\n", 1);
    // A different client can finish while the same client remains behind the
    // outstanding sender belonging to the first attachment.
    try submit(second, 2, "GET /2 HTTP/1.1\r\n\r\n", 1);
    try other.wait(.delivered, 2, 1);
    state.mutex.lock();
    const mutations = state.fs_entered[3];
    state.mutex.unlock();
    try t.expectEqual(0, mutations);
    try close(second, 1);
    try submit(second, 1, "GET /4 HTTP/1.1\r\n\r\n", 1);
    try other.wait(.delivered, 1, 1);
    first.stop();
    first.join();
    second.stop();
    second.join();
    try t.expectEqual(0, state.delivered[1]);
    try t.expectEqual(0, state.fs_entered[3]);
    try t.expectEqual(1, state.fs_entered[4]);
}
