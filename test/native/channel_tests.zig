const std = @import("std");
const t = std.testing;
const s = @import("spice");
const a = t.allocator;
const key: s.barrier.Key = .{ .kind = 2, .id = 0 };
pub const Fake = struct {
    input: []const u8,
    offset: usize = 0,
    output: s.bytes.Writer = .{ .allocator = a, .limit = 1024 * 1024 },
    cancelled: bool = false,
    fail_write: bool = false,
    pub fn io(self: *Fake) s.channel.IO {
        return .{ .context = self, .read_fn = read, .write_fn = write, .cancel_fn = cancel };
    }
    fn read(ctx: *anyopaque, buffer: []u8) !usize {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        const count = @min(@min(buffer.len, 7), self.input.len - self.offset);
        @memcpy(buffer[0..count], self.input[self.offset..][0..count]);
        self.offset += count;
        return count;
    }
    fn write(ctx: *anyopaque, bytes: []const u8) !void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (self.fail_write) return error.ConnectionFailed;
        try self.output.append(bytes);
    }
    fn cancel(ctx: *anyopaque) void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.cancelled = true;
    }
};
pub fn frame(out: *s.bytes.Writer, serial: ?u64, kind: u16, body: []const u8) !void {
    if (serial) |v| try out.write(u64, v);
    try out.write(u16, kind);
    try out.write(u32, @intCast(body.len));
    if (serial != null) try out.write(u32, 0);
    try out.append(body);
}
// Independent LIST bytes: two logical messages ordered by the offset table.
const list = [_]u8{ 2, 0, 17, 0, 0, 0, 10, 0, 0, 0, 0x59, 2, 1, 0, 0, 0, 0x61, 0x5a, 2, 2, 0, 0, 0, 0x62, 0x63 };
test "channel LIST handler completion publishes serial and one physical ACK; retained delivery survives" {
    const b = try s.barrier.Barrier.create(a);
    defer b.destroy();
    var input: s.bytes.Writer = .{ .allocator = a, .limit = 1024 * 1024 };
    defer input.deinit();
    try frame(&input, 42, 8, &list);
    var fake: Fake = .{ .input = input.bytes.items };
    defer fake.output.deinit();
    var c = s.channel.Channel.init(a, key, fake.io(), .full, b);
    c.configureAck(7, 1);
    const first = try c.receive();
    defer first.deinit();
    try t.expectEqual(@as(u16, 602), first.message.kind);
    try t.expect(!try b.check(&.{.{ .key = key, .serial = 42 }}));
    try c.complete();
    try t.expectEqual(@as(usize, 0), fake.output.bytes.items.len);
    const last = try c.receive();
    defer last.deinit();
    try t.expectEqual(@as(u16, 601), last.message.kind);
    try c.complete();
    try t.expect(try b.check(&.{.{ .key = key, .serial = 42 }}));
    try t.expectEqual(@as(usize, 18), fake.output.bytes.items.len);
    try t.expectEqual(@as(u8, 2), fake.output.bytes.items[8]);
    c.deinit();
    try t.expectEqualSlices(u8, &.{ 0x62, 0x63 }, first.message.body.bytes());
    try t.expectError(error.ChannelTerminated, b.check(&.{.{ .key = key, .serial = 43 }}));
}
test "SET_ACK inside LIST excludes entire batch; empty LIST advances ACK and serial" {
    const b = try s.barrier.Barrier.create(a);
    defer b.destroy();
    var input: s.bytes.Writer = .{ .allocator = a, .limit = 1024 * 1024 };
    defer input.deinit();
    try frame(&input, 1, 8, &list);
    try frame(&input, 2, 8, &.{ 0, 0 });
    try frame(&input, 3, 601, &.{});
    var fake: Fake = .{ .input = input.bytes.items };
    defer fake.output.deinit();
    var c = s.channel.Channel.init(a, key, fake.io(), .full, b);
    defer c.deinit();
    var e = try c.receive();
    e.deinit();
    c.configureAck(1, 1);
    try c.complete();
    e = try c.receive();
    e.deinit();
    try c.complete();
    try t.expectEqual(@as(usize, 0), fake.output.bytes.items.len);
    e = try c.receive();
    defer e.deinit();
    try t.expectEqual(@as(usize, 18), fake.output.bytes.items.len);
    try t.expect(try b.check(&.{.{ .key = key, .serial = 2 }}));
    try t.expect(!try b.check(&.{.{ .key = key, .serial = 3 }}));
    try c.complete();
    try t.expectEqual(@as(usize, 36), fake.output.bytes.items.len);
}
test "mini serials require complete; double receive and failed ACK terminate without publishing" {
    for ([_]bool{ false, true }) |fail| {
        const b = try s.barrier.Barrier.create(a);
        defer b.destroy();
        var input: s.bytes.Writer = .{ .allocator = a, .limit = 1024 * 1024 };
        defer input.deinit();
        try frame(&input, null, 601, &.{});
        var fake: Fake = .{ .input = input.bytes.items, .fail_write = fail };
        defer fake.output.deinit();
        var c = s.channel.Channel.init(a, key, fake.io(), .mini, b);
        defer c.deinit();
        c.configureAck(1, 1);
        const e = try c.receive();
        defer e.deinit();
        try t.expectEqual(@as(u64, 1), e.message.effective_serial);
        if (fail) try t.expectError(error.ConnectionFailed, c.complete()) else try t.expectError(error.InvalidState, c.receive());
        try t.expect(fake.cancelled);
        try t.expectError(error.ChannelTerminated, b.check(&.{.{ .key = key, .serial = 1 }}));
    }
}
test "migration flush then ACK then retained data, blocked ordinary send and resume" {
    const b = try s.barrier.Barrier.create(a);
    defer b.destroy();
    var input: s.bytes.Writer = .{ .allocator = a, .limit = 1024 * 1024 };
    defer input.deinit();
    try frame(&input, null, 1, &.{ 3, 0, 0, 0 });
    try frame(&input, null, 2, &.{ 9, 8, 7 });
    var fake: Fake = .{ .input = input.bytes.items };
    defer fake.output.deinit();
    var c = s.channel.Channel.init(a, key, fake.io(), .mini, b);
    defer c.deinit();
    c.configureAck(1, 1);
    const e = try c.receive();
    defer e.deinit();
    try t.expectEqualSlices(u8, &.{ 9, 8, 7 }, e.migration.?.bytes());
    try t.expectEqualSlices(u8, &.{ 4, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0 }, fake.output.bytes.items);
    try t.expect(try b.check(&.{.{ .key = key, .serial = 2 }}));
    try t.expectError(error.InvalidState, c.send(100, &.{}));
    c.resumeMigration();
    try c.send(100, &.{});
}
test "migration rejects flags and unsolicited data; supersede preserves fulfilled serial and replacement" {
    for ([_]u16{ 1, 2 }) |kind| {
        const b = try s.barrier.Barrier.create(a);
        defer b.destroy();
        var input: s.bytes.Writer = .{ .allocator = a, .limit = 1024 * 1024 };
        defer input.deinit();
        try frame(&input, null, kind, &.{ 4, 0, 0, 0 });
        var fake: Fake = .{ .input = input.bytes.items };
        defer fake.output.deinit();
        var c = s.channel.Channel.init(a, key, fake.io(), .mini, b);
        defer c.deinit();
        if (kind == 1) try t.expectError(error.InvalidMigrationFlags, c.receive()) else try t.expectError(error.UnexpectedMigrationData, c.receive());
    }
    const b = try s.barrier.Barrier.create(a);
    defer b.destroy();
    var fake: Fake = .{ .input = &.{} };
    defer fake.output.deinit();
    var old = s.channel.Channel.init(a, key, fake.io(), .full, b);
    old.supersede(true);
    try t.expectError(error.InvalidState, old.send(100, &.{}));
    try old.activate();
    old.supersede(true);
    old.deinit();
    b.record(key, 50);
    try t.expect(try b.check(&.{.{ .key = key, .serial = 50 }}));
}
const Wait = struct {
    barrier: *s.barrier.Barrier,
    token: s.barrier.Token = .{},
    result: ?anyerror = null,
    done: bool = false,
    fn run(self: *Wait) void {
        self.barrier.wait(&.{ .{ .key = key, .serial = 7 }, .{ .key = .{ .kind = 3, .id = 1 }, .serial = 4 } }, &self.token) catch |err| {
            self.result = err;
        };
        self.done = true;
    }
};
test "barrier concurrent wait completion termination and per-wait cancellation" {
    for (0..3) |mode| {
        const b = try s.barrier.Barrier.create(a);
        defer b.destroy();
        var waiter: Wait = .{ .barrier = b };
        const thread = try std.Thread.spawn(.{}, Wait.run, .{&waiter});
        b.record(key, 7);
        b.record(key, 2);
        if (mode == 0) b.record(.{ .kind = 3, .id = 1 }, 4) else if (mode == 1) b.terminate(.{ .kind = 3, .id = 1 }) else b.cancel(&waiter.token);
        thread.join();
        try t.expect(waiter.done);
        if (mode == 0) try t.expect(waiter.result == null) else try t.expectEqual(if (mode == 1) error.ChannelTerminated else error.Cancelled, waiter.result.?);
    }
}
fn allocationRun(allocator: std.mem.Allocator) !void {
    const b = try s.barrier.Barrier.create(allocator);
    defer b.destroy();
    var input: s.bytes.Writer = .{ .allocator = a, .limit = 1024 * 1024 };
    defer input.deinit();
    try frame(&input, 1, 8, &list);
    var fake: Fake = .{ .input = input.bytes.items };
    defer fake.output.deinit();
    var c = s.channel.Channel.init(allocator, key, fake.io(), .full, b);
    defer c.deinit();
    for (0..2) |_| {
        const e = try c.receive();
        defer e.deinit();
        try c.complete();
    }
    try c.send(100, &.{ 1, 2, 3 });
}
test "channel every allocation failure releases batches and outbound storage" {
    try t.checkAllAllocationFailures(a, allocationRun, .{});
}

const LargeWriter = struct {
    calls: usize = 0,
    bytes: usize = 0,
    cancelled: bool = false,
    fail_suffix: bool = false,
    fn read(_: *anyopaque, _: []u8) !usize {
        return error.ConnectionClosed;
    }
    fn write(ctx: *anyopaque, bytes: []const u8) !void {
        const self: *LargeWriter = @ptrCast(@alignCast(ctx));
        try t.expect(bytes.len <= 64 * 1024 * 1024);
        self.calls += 1;
        if (self.fail_suffix and self.calls == 2) return error.ConnectionFailed;
        self.bytes += bytes.len;
    }
    fn cancel(ctx: *anyopaque) void {
        const self: *LargeWriter = @ptrCast(@alignCast(ctx));
        self.cancelled = true;
    }
};
test "64MiB legal full and mini bodies use bounded writes; oversized body emits nothing; suffix failure closes" {
    const data = try a.alloc(u8, 64 * 1024 * 1024 + 1);
    defer a.free(data);
    @memset(data, 0x5a);
    for ([_]s.framer.Mode{ .full, .mini }) |mode| {
        const b = try s.barrier.Barrier.create(a);
        defer b.destroy();
        var writer: LargeWriter = .{};
        var c = s.channel.Channel.init(a, key, .{ .context = &writer, .read_fn = LargeWriter.read, .write_fn = LargeWriter.write, .cancel_fn = LargeWriter.cancel }, mode, b);
        defer c.deinit();
        try t.expectError(error.MessageTooLarge, c.send(601, data));
        try t.expectEqual(@as(usize, 0), writer.calls);
        try t.expect(!writer.cancelled);
        try c.send(601, data[0 .. 64 * 1024 * 1024]);
        try t.expectEqual(@as(usize, 2), writer.calls);
        try t.expectEqual(@as(usize, 64 * 1024 * 1024) + mode.size(), writer.bytes);
        writer.calls = 0;
        writer.fail_suffix = true;
        try t.expectError(error.ConnectionFailed, c.send(601, data[0 .. 64 * 1024 * 1024]));
        try t.expect(writer.cancelled);
    }
}
