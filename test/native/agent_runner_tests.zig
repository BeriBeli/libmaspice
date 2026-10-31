const std = @import("std");
const s = @import("spice");
const t = std.testing;
extern "c" fn usleep(u32) c_int;
pub const Runtime = struct {
    const Boot = struct { agent_epoch: u64 = 1, agent_connected: bool = true };
    pub const Group = struct { bootstrap: ?Boot = Boot{} };
    pub const Event = s.supervisor.Supervisor(s.desktop_child).Event;
    mutex: s.sync.Mutex = .{},
    phase: enum { ready } = .ready,
    stopping: bool = false,
    active: ?*Group,
    lifecycle: u64 = 1,
    allowed: std.atomic.Value(bool) = .init(true),
    attempts: std.atomic.Value(usize) = .init(0),
    sent_mutex: s.sync.Mutex = .{},
    sent: [128]u32 = undefined,
    count: usize = 0,
    pub fn sendAgentAt(self: *Runtime, epoch: s.supervisor.AgentEpoch, _: u32, kind: u32, _: u64, _: []const u8, token: *s.cancel.Token) anyerror!bool {
        try token.check();
        if (epoch.session != 1 or epoch.agent != 1) return error.StaleAgentGeneration;
        _ = self.attempts.fetchAdd(1, .acq_rel);
        if (!self.allowed.load(.acquire)) return false;
        self.sent_mutex.lock();
        defer self.sent_mutex.unlock();
        if (self.count == self.sent.len) return error.CaptureFull;
        self.sent[self.count] = kind;
        self.count += 1;
        return true;
    }
    fn countKind(self: *Runtime, kind: u32) usize {
        self.sent_mutex.lock();
        defer self.sent_mutex.unlock();
        var n: usize = 0;
        for (self.sent[0..self.count]) |v| {
            if (v == kind) n += 1;
        }
        return n;
    }
    pub fn deinit(self: *Runtime) void {
        self.mutex.deinit();
        self.sent_mutex.deinit();
    }
};
const Gate = struct {
    mutex: s.sync.Mutex = .{},
    changed: s.sync.Condition = .{},
    block: bool = false,
    entered: std.atomic.Value(usize) = .init(0),
    fn wake(p: *anyopaque) void {
        const self: *Gate = @ptrCast(@alignCast(p));
        self.mutex.lock();
        self.changed.broadcast();
        self.mutex.unlock();
    }
    fn wait(self: *Gate, token: *s.cancel.Token) !void {
        var registration: s.cancel.Registration = .{ .context = self, .wake = wake };
        token.register(&registration);
        defer token.unregister(&registration);
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.entered.fetchAdd(1, .acq_rel);
        while (self.block) {
            try token.check();
            self.changed.wait(&self.mutex);
        }
        try token.check();
    }
    fn set(self: *Gate, value: bool) void {
        self.mutex.lock();
        self.block = value;
        self.changed.broadcast();
        self.mutex.unlock();
    }
    fn deinit(self: *Gate) void {
        self.changed.deinit();
        self.mutex.deinit();
    }
};
const BoardState = struct {
    refs: std.atomic.Value(usize) = .init(1),
    reads: Gate = .{},
    writes: Gate = .{},
    committed: std.atomic.Value(usize) = .init(0),
    fn deinit(self: *BoardState) void {
        std.debug.assert(self.refs.load(.acquire) == 1);
        self.reads.deinit();
        self.writes.deinit();
    }
};
const Board = struct {
    state: *BoardState,
    pub fn retain(self: Board) Board {
        _ = self.state.refs.fetchAdd(1, .acq_rel);
        return self;
    }
    pub fn deinit(self: Board) void {
        _ = self.state.refs.fetchSub(1, .acq_rel);
    }
    pub const Snapshot = struct {
        change_count: i64,
        size: usize = 5,
        oversized: bool = false,
        pub fn deinit(_: Snapshot) void {}
        pub fn bytes(self: Snapshot) !?[]const u8 {
            return if (self.change_count == 0) "local" else "guest";
        }
    };
    pub fn snapshot(self: Board, _: usize, token: *s.cancel.Token) !Snapshot {
        try self.state.reads.wait(token);
        return .{ .change_count = @intCast(self.state.committed.load(.acquire)) };
    }
    pub fn write(self: Board, text: []const u8, _: usize, token: *s.cancel.Token) !Snapshot {
        try t.expectEqualStrings("guest", text);
        try self.state.writes.wait(token);
        return .{ .change_count = @intCast(self.state.committed.fetchAdd(1, .acq_rel) + 1) };
    }
};
const Runner = s.agent_runner.Runner(Runtime, Board);
fn waitAtomic(value: *std.atomic.Value(usize), minimum: usize) !void {
    for (0..3000) |_| {
        if (value.load(.acquire) >= minimum) return;
        _ = usleep(1000);
    }
    return error.TestTimeout;
}
fn waitKind(runtime: *Runtime, kind: u32, minimum: usize) !void {
    for (0..3000) |_| {
        if (runtime.countKind(kind) >= minimum) return;
        _ = usleep(1000);
    }
    return error.TestTimeout;
}
fn observe(runner: *Runner, kind: u32, data: []const u8) !void {
    const body = try s.bytes.Slice.copy(t.allocator, data);
    defer body.release();
    try runner.observe(.{ .generation = 1, .lifecycle = 1, .value = .{ .main = .{ .agent_message = .{ .protocol = 1, .kind = kind, .opaque_id = 0, .data = body, .epoch = 1 } } } });
}
fn negotiate(runner: *Runner) !void {
    const m = try s.agent_services_wire.encodeClipboard(t.allocator, .{ .capabilities = .{ .reply = false, .values = s.agent_services_wire.Capabilities.desktop(true) } }, 0);
    defer m.deinit();
    try observe(runner, m.kind, m.data.bytes());
}
test "Agent runner opt-in polling retries token backpressure without an incoming event and suppresses host-write echoes" {
    var group: Runtime.Group = .{};
    var runtime: Runtime = .{ .active = &group };
    defer runtime.deinit();
    runtime.allowed.store(false, .release);
    var board: BoardState = .{};
    defer board.deinit();
    const runner = try Runner.create(t.allocator, &runtime, .{ .state = &board }, .{ .poll_ms = 10 });
    defer runner.destroy();
    try waitAtomic(&runtime.attempts, 1);
    try t.expectEqual(@as(usize, 0), board.reads.entered.load(.acquire));
    runtime.allowed.store(true, .release);
    try waitKind(&runtime, 6, 1);
    try runner.setClipboardEnabled(true);
    try negotiate(runner);
    try waitKind(&runtime, 7, 1);
    try observe(runner, 7, &.{ 1, 0, 0, 0 });
    try waitKind(&runtime, 8, 1);
    try observe(runner, 4, &.{ 1, 0, 0, 0, 'g', 'u', 'e', 's', 't' });
    try waitAtomic(&board.committed, 1);
    const before = board.reads.entered.load(.acquire);
    try waitAtomic(&board.reads.entered, before + 2);
    try t.expectEqual(@as(usize, 1), runtime.countKind(7));
    var retained: ?s.agent_runner.Output = null;
    defer if (retained) |v| v.deinit();
    while (runner.next()) |out| {
        if (out == .failed) {
            out.deinit();
            return error.UnexpectedRunnerFailure;
        }
        if (out == .agent and out.agent == .clipboard and out.agent.clipboard == .guest_text) {
            retained = out;
        } else out.deinit();
    }
    try t.expect(retained != null);
    try t.expectEqualStrings("guest", retained.?.agent.clipboard.guest_text.bytes());
}
test "Agent runner disable cancels queued host read and write before admitting later policy epochs" {
    var group: Runtime.Group = .{};
    var runtime: Runtime = .{ .active = &group };
    defer runtime.deinit();
    var board: BoardState = .{};
    defer board.deinit();
    board.reads.set(true);
    const runner = try Runner.create(t.allocator, &runtime, .{ .state = &board }, .{ .poll_ms = 10, .manager = .{ .clipboard_enabled = true } });
    defer runner.destroy();
    try waitAtomic(&board.reads.entered, 1);
    try runner.setClipboardEnabled(false);
    try waitKind(&runtime, 6, 2);
    board.reads.set(false);
    board.writes.set(true);
    try runner.setClipboardEnabled(true);
    try negotiate(runner);
    try waitKind(&runtime, 7, 1);
    try observe(runner, 7, &.{ 1, 0, 0, 0 });
    try waitKind(&runtime, 8, 1);
    try observe(runner, 4, &.{ 1, 0, 0, 0, 'g', 'u', 'e', 's', 't' });
    try waitAtomic(&board.writes.entered, 1);
    const caps = runtime.countKind(6);
    try runner.setClipboardEnabled(false);
    try waitKind(&runtime, 6, caps + 1);
    try t.expectEqual(@as(usize, 0), board.committed.load(.acquire));
    // Retrying enabled later must not resurrect the cancelled guest-write action.
    board.writes.set(false);
    try runner.setClipboardEnabled(true);
    try waitKind(&runtime, 6, caps + 2);
    try waitAtomic(&board.reads.entered, 2);
    try t.expectEqual(@as(usize, 0), board.committed.load(.acquire));
}
fn creation(a: std.mem.Allocator) !void {
    var group: Runtime.Group = .{};
    var runtime: Runtime = .{ .active = &group };
    defer runtime.deinit();
    var board: BoardState = .{};
    defer board.deinit();
    const runner = try Runner.create(a, &runtime, .{ .state = &board }, .{ .poll_ms = 60000 });
    runner.destroy();
}
test "Agent runner bounded command ownership and creation allocation failures join workers" {
    try t.checkAllAllocationFailures(t.allocator, creation, .{});
    var group: Runtime.Group = .{};
    var runtime: Runtime = .{ .active = &group };
    defer runtime.deinit();
    var board: BoardState = .{};
    defer board.deinit();
    board.reads.set(true);
    const runner = try Runner.create(t.allocator, &runtime, .{ .state = &board }, .{ .poll_ms = 10, .manager = .{ .clipboard_enabled = true } });
    defer runner.destroy();
    try waitAtomic(&board.reads.entered, 1);
    for (0..64) |_| try observe(runner, 9, &.{});
    try t.expectError(error.AgentWorkQueueFull, observe(runner, 9, &.{}));
    runner.stop();
    for (0..3000) |_| {
        if (runner.status().finished) break;
        _ = usleep(1000);
    }
    try t.expect(runner.status().finished);
}

test "Agent runner policy allocation failure terminates without restoring host access" {
    var group: Runtime.Group = .{};
    var runtime: Runtime = .{ .active = &group };
    defer runtime.deinit();
    var board: BoardState = .{};
    defer board.deinit();
    board.reads.set(true);
    var failing = t.FailingAllocator.init(t.allocator, .{});
    const runner = try Runner.create(failing.allocator(), &runtime, .{ .state = &board }, .{ .poll_ms = 10, .manager = .{ .clipboard_enabled = true } });
    defer runner.destroy();
    try waitAtomic(&board.reads.entered, 1);
    // Worker is parked in the explicit host gate; no allocator operation is live.
    failing.fail_index = failing.alloc_index;
    try runner.setClipboardEnabled(false);
    for (0..3000) |_| {
        if (runner.status().finished) break;
        _ = usleep(1000);
    }
    try t.expect(runner.status().finished);
    try t.expectEqual(error.OutOfMemory, runner.status().failure.?);
    try t.expectEqual(@as(usize, 0), board.committed.load(.acquire));
}

fn completed(runner: *Runner, request: u64) !void {
    for (0..3000) |_| {
        while (runner.next()) |out| {
            defer out.deinit();
            if (out == .completed and out.completed == request) return;
            if (out == .failed and out.failed.request == request) return out.failed.reason;
        }
        _ = usleep(1000);
    }
    return error.TestTimeout;
}
test "manual Agent host operations complete in order and disabled policy revokes publication" {
    var group: Runtime.Group = .{};
    var runtime: Runtime = .{ .active = &group };
    defer runtime.deinit();
    var board: BoardState = .{};
    defer board.deinit();
    const runner = try Runner.create(t.allocator, &runtime, .{ .state = &board }, .{ .automatic_poll = false, .first_file_id = 42, .manager = .{ .clipboard_enabled = true } });
    defer runner.destroy();
    try negotiate(runner);
    try runner.barrier(1);
    try completed(runner, 1);
    try t.expectEqual(@as(usize, 0), board.reads.entered.load(.acquire));
    try runner.synchronize(2);
    try completed(runner, 2);
    try t.expectEqual(@as(usize, 1), board.reads.entered.load(.acquire));
    try runner.publish(3, "guest");
    try completed(runner, 3);
    try t.expectEqual(@as(usize, 1), board.committed.load(.acquire));
    try runner.setClipboardEnabled(false);
    try runner.barrier(4);
    try completed(runner, 4);
    try runner.publish(5, "guest");
    try completed(runner, 5);
    try t.expectEqual(@as(usize, 1), board.committed.load(.acquire));
    runner.join();
    const metrics = runner.diagnostics();
    try t.expectEqual(@as(u64, 1), metrics.inbound);
    try t.expectEqual(@as(u64, 1), metrics.capabilities);
    try t.expectEqual(@as(u32, 1), metrics.has_peer);
    try t.expectEqual(@as(u32, 1), metrics.peer_demand);
    try t.expect(metrics.capability_sent >= 2);
    try t.expectEqual(@as(u32, 42), runner.nextFileID());
}
test "Agent may start before connection and late attach replays current owned messages" {
    var runtime: Runtime = .{ .active = null };
    defer runtime.deinit();
    var board: BoardState = .{};
    defer board.deinit();
    const runner = try Runner.create(t.allocator, &runtime, .{ .state = &board }, .{ .automatic_poll = false });
    defer runner.destroy();
    var route: s.agent_route.Route(Runtime, Runner) = .{};
    defer route.deinit();
    var group: Runtime.Group = .{};
    runtime.mutex.lock();
    runtime.active = &group;
    runtime.mutex.unlock();
    try route.observe(.{ .generation = 1, .lifecycle = 1, .value = .connected });
    {
        const message = try s.agent_services_wire.encodeClipboard(t.allocator, .{ .capabilities = .{ .reply = false, .values = s.agent_services_wire.Capabilities.desktop(true) } }, 0);
        defer message.deinit();
        try route.observe(.{ .generation = 1, .lifecycle = 1, .value = .{ .main = .{ .agent_message = .{ .protocol = 1, .kind = message.kind, .opaque_id = 0, .data = message.data, .epoch = 1 } } } });
    }
    try route.attach(runner);
    defer route.detach(runner);
    try t.expectError(error.AgentAlreadyAttached, route.attach(runner));
    try runner.barrier(9);
    try completed(runner, 9);
    try t.expectEqual(@as(u64, 1), runner.diagnostics().capabilities);
    try t.expectEqual(@as(usize, 0), board.reads.entered.load(.acquire));
    try route.observe(.{ .generation = 1, .lifecycle = 1, .value = .disconnected });
    try runner.barrier(10);
    try completed(runner, 10);
}
