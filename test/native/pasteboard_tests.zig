const std = @import("std");
const s = @import("spice");
const t = std.testing;
extern "c" fn pasteboard_probe_create() ?*anyopaque;
extern "c" fn pasteboard_probe_name(*anyopaque) [*:0]const u8;
extern "c" fn pasteboard_probe_destroy(*anyopaque) void;
extern "c" fn pasteboard_probe_drain() c_int;
extern "c" fn usleep(u32) c_int;
extern "c" fn pasteboard_swift_roundtrip([*]const u8, usize, [*]u8, usize) isize;
test "Private pasteboard roundtrip matches unchanged Swift AppKit bridge and snapshot ownership" {
    const board = pasteboard_probe_create() orelse return error.PasteboardUnavailable;
    defer pasteboard_probe_destroy(board);
    const context = try s.pasteboard.Context.init(std.mem.span(pasteboard_probe_name(board)));
    var alive = true;
    defer if (alive) context.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const initial = try context.snapshot(100, &token);
    defer initial.deinit();
    try t.expect(!initial.present);
    var last = initial.change_count;
    for ([_][]const u8{ "hello", "", "\xef\xbb\xbf", "\xef\xbb\xbf\xef\xbb\xbfx", "你好🙂", "a\x00b" }) |text| {
        const snapshot = try context.write(text, 100, &token);
        defer snapshot.deinit();
        try t.expect(snapshot.present and !snapshot.oversized and snapshot.change_count > last);
        var oracle: [100]u8 = undefined;
        const count = pasteboard_swift_roundtrip(text.ptr, text.len, &oracle, oracle.len);
        try t.expect(count >= 0);
        try t.expectEqualStrings(oracle[0..@intCast(count)], (try snapshot.bytes()).?);
        last = snapshot.change_count;
    }
    const retained = try context.snapshot(100, &token);
    defer retained.deinit();
    context.deinit();
    alive = false;
    try t.expectEqualStrings("a\x00b", (try retained.bytes()).?);
}
test "Private pasteboard oversized capture avoids payload materialization and rejected writes do not mutate" {
    const board = pasteboard_probe_create() orelse return error.PasteboardUnavailable;
    defer pasteboard_probe_destroy(board);
    const context = try s.pasteboard.Context.init(std.mem.span(pasteboard_probe_name(board)));
    defer context.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const big = try context.write("large", 2, &token);
    defer big.deinit();
    try t.expect(big.present and big.oversized and big.size == 5);
    try t.expectError(error.OversizedLocalText, big.bytes());
    try t.expectError(error.InvalidUTF8, context.write(&.{255}, 100, &token));
    var cancelled: s.cancel.Token = .{};
    defer cancelled.deinit();
    cancelled.cancel();
    try t.expectError(error.Cancelled, context.write("blocked", 100, &cancelled));
    const actual = try context.snapshot(100, &token);
    defer actual.deinit();
    try t.expectEqual(big.change_count, actual.change_count);
    try t.expectEqualStrings("large", (try actual.bytes()).?);
}
const Job = struct {
    context: s.pasteboard.Context,
    token: s.cancel.Token = .{},
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        const snapshot = self.context.write("cancelled", 100, &self.token) catch |err| {
            self.failure = err;
            return;
        };
        snapshot.deinit();
    }
};
test "Queued main-thread pasteboard cancellation joins while main is blocked and releases callback before drain" {
    const board = pasteboard_probe_create() orelse return error.PasteboardUnavailable;
    defer pasteboard_probe_destroy(board);
    const name = std.mem.span(pasteboard_probe_name(board));
    const context = try s.pasteboard.Context.init(name);
    var alive = true;
    defer if (alive) context.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const before = try context.write("original", 100, &token);
    defer before.deinit();
    var job: Job = .{ .context = context };
    defer job.token.deinit();
    const thread = try std.Thread.spawn(.{}, Job.run, .{&job});
    var joined = false;
    defer if (!joined) {
        job.token.cancel();
        _ = pasteboard_probe_drain();
        thread.join();
    };
    for (0..3000) |_| {
        if (context.pending()) break;
        _ = usleep(1000);
    }
    try t.expect(context.pending());
    job.token.cancel();
    for (0..3000) |_| {
        if (job.done.load(.acquire)) break;
        _ = usleep(1000);
    }
    try t.expect(job.done.load(.acquire));
    thread.join();
    joined = true;
    try t.expectEqual(error.Cancelled, job.failure.?);
    try t.expectError(error.PasteboardBusy, context.snapshot(100, &token));
    context.deinit();
    alive = false;
    try t.expectEqual(@as(c_int, 1), pasteboard_probe_drain());
    const fresh = try s.pasteboard.Context.init(name);
    defer fresh.deinit();
    const actual = try fresh.snapshot(100, &token);
    defer actual.deinit();
    try t.expectEqual(before.change_count, actual.change_count);
    try t.expectEqualStrings("original", (try actual.bytes()).?);
}

test "Native Agent runner destruction joins a queued main-thread read without draining main" {
    const Runtime = @import("agent_runner_tests.zig").Runtime;
    const Runner = s.agent_runner.Runner(Runtime, s.pasteboard.Context);
    var group: Runtime.Group = .{};
    var runtime: Runtime = .{ .active = &group };
    defer runtime.deinit();
    const board = pasteboard_probe_create() orelse return error.PasteboardUnavailable;
    defer pasteboard_probe_destroy(board);
    const context = try s.pasteboard.Context.init(std.mem.span(pasteboard_probe_name(board)));
    defer context.deinit();
    const runner = try Runner.create(t.allocator, &runtime, context, .{ .poll_ms = 10, .manager = .{ .clipboard_enabled = true } });
    var alive = true;
    defer if (alive) runner.destroy();
    for (0..3000) |_| {
        if (context.pending()) break;
        _ = usleep(1000);
    }
    try t.expect(context.pending());
    runner.destroy();
    alive = false;
    try t.expectEqual(@as(c_int, 1), pasteboard_probe_drain());
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const actual = try context.snapshot(100, &token);
    defer actual.deinit();
    try t.expect(!actual.present);
}

extern "c" fn pasteboard_probe_matches(*anyopaque, [*]const u8, usize) c_int;
const LocalRuntime = @import("agent_runner_tests.zig").Runtime;
const LocalRunner = s.agent_runner.Runner(LocalRuntime, s.pasteboard.Context);
const Publication = struct {
    runner: *LocalRunner,
    text: []const u8,
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    fn run(self: *Publication) void {
        defer self.done.store(true, .release);
        self.runner.publishBorrowed(self.text) catch |err| {
            self.failure = err;
        };
    }
};
fn publishLocal(runner: *LocalRunner, text: []const u8) !void {
    var job: Publication = .{ .runner = runner, .text = text };
    const thread = try std.Thread.spawn(.{}, Publication.run, .{&job});
    defer thread.join();
    errdefer runner.stop();
    for (0..3000) |_| {
        if (job.done.load(.acquire)) break;
        _ = pasteboard_probe_drain();
        _ = usleep(1000);
    }
    if (!job.done.load(.acquire)) return error.TestTimeout;
    if (job.failure) |err| return err;
}
fn localBarrier(runner: *LocalRunner, request: u64) !usize {
    try runner.barrier(request);
    var oversized: usize = 0;
    for (0..3000) |_| {
        while (runner.next()) |event| {
            defer event.deinit();
            switch (event) {
                .completed => |id| if (id == request) {
                    return oversized;
                },
                .failed => |failure| return failure.reason,
                .agent => |agent| if (agent == .clipboard and agent.clipboard == .oversized_local) {
                    oversized += 1;
                },
                else => {},
            }
        }
        _ = pasteboard_probe_drain();
        _ = usleep(1000);
    }
    return error.TestTimeout;
}
test "Explicit large local publication borrows caller bytes and preserves bounded snapshot policy" {
    var group: LocalRuntime.Group = .{};
    var runtime: LocalRuntime = .{ .active = &group };
    defer runtime.deinit();
    const board = pasteboard_probe_create() orelse return error.PasteboardUnavailable;
    defer pasteboard_probe_destroy(board);
    const context = try s.pasteboard.Context.init(std.mem.span(pasteboard_probe_name(board)));
    defer context.deinit();
    const runner = try LocalRunner.create(t.allocator, &runtime, context, .{ .automatic_poll = false, .manager = .{ .clipboard_enabled = true, .maximum_text = 32 } });
    defer runner.destroy();
    const text = try t.allocator.alloc(u8, 33 * 1024 * 1024);
    defer t.allocator.free(text);
    @memset(text, 'x');
    var token: s.cancel.Token = .{};
    defer token.deinit();
    for ([_]usize{ 31, 32, 33, text.len }, 1..) |size, id| {
        try publishLocal(runner, text[0..size]);
        try t.expectEqual(@as(usize, if (size > 32) 1 else 0), try localBarrier(runner, id));
        try t.expectEqual(@as(c_int, 1), pasteboard_probe_matches(board, text.ptr, size));
        const snapshot = try context.snapshot(32, &token);
        defer snapshot.deinit();
        try t.expectEqual(size, snapshot.size);
        try t.expectEqual(size > 32, snapshot.oversized);
        try runner.synchronize(100 + id);
        try t.expectEqual(@as(usize, 0), try localBarrier(runner, 200 + id));
        // Repeated snapshot changeCount produces no duplicate oversized event.
        try t.expectEqual(@as(usize, 0), try localBarrier(runner, 300 + id));
    }
    try runner.setClipboardEnabled(false);
    _ = try localBarrier(runner, 401);
    try publishLocal(runner, "disabled");
    try t.expectEqual(@as(c_int, 1), pasteboard_probe_matches(board, text.ptr, text.len));
    try runner.setClipboardEnabled(true);
    _ = try localBarrier(runner, 402);
    try runner.synchronize(403);
    try t.expectEqual(@as(usize, 1), try localBarrier(runner, 404));
    try t.expectError(error.InvalidUTF8, runner.publishBorrowed(&.{255}));
    try t.expectError(error.InvalidUTF8, runner.publish(405, text));
}
test "Stopping Agent wakes a borrowed local publication without draining AppKit" {
    var group: LocalRuntime.Group = .{};
    var runtime: LocalRuntime = .{ .active = &group };
    defer runtime.deinit();
    const board = pasteboard_probe_create() orelse return error.PasteboardUnavailable;
    defer pasteboard_probe_destroy(board);
    const context = try s.pasteboard.Context.init(std.mem.span(pasteboard_probe_name(board)));
    defer context.deinit();
    const runner = try LocalRunner.create(t.allocator, &runtime, context, .{ .automatic_poll = false, .manager = .{ .clipboard_enabled = true } });
    defer runner.destroy();
    var job: Publication = .{ .runner = runner, .text = "never written" };
    const thread = try std.Thread.spawn(.{}, Publication.run, .{&job});
    defer thread.join();
    defer runner.stop();
    for (0..3000) |_| {
        if (context.pending()) break;
        _ = usleep(1000);
    }
    try t.expect(context.pending());
    runner.join();
    for (0..3000) |_| {
        if (job.done.load(.acquire)) break;
        _ = usleep(1000);
    }
    try t.expect(job.done.load(.acquire));
    try t.expectEqual(error.Cancelled, job.failure.?);
    _ = pasteboard_probe_drain();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const snapshot = try context.snapshot(32, &token);
    defer snapshot.deinit();
    try t.expect(!snapshot.present);
}
