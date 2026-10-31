const std = @import("std");
const s = @import("spice");
const t = std.testing;
const p = s.agent_services_wire;
fn clipboardLifecycle(a: std.mem.Allocator) !void {
    var state = s.clipboard.State.init(a, 8, true);
    defer state.deinit();
    const connected = try state.connected();
    defer connected.deinit();
    try t.expectEqual(@as(usize, 1), connected.count);
    try t.expect(state.support().monitors and !state.support().files);
    const retry = try state.announcementIfNeeded();
    defer retry.deinit();
    try t.expectEqual(@as(usize, 1), retry.count);
    state.didSend(connected.items[0].send.kind);
    const done = try state.announcementIfNeeded();
    defer done.deinit();
    try t.expectEqual(@as(usize, 0), done.count);
    const local = try state.localChanged(1, "hello");
    defer local.deinit();
    try t.expectEqual(@as(usize, 0), local.count);
    var caps: p.Capabilities = .{ .count = 1 };
    caps.words[0] = 1 << 5;
    const negotiated = try state.receive(.{ .capabilities = .{ .reply = true, .values = caps } });
    defer negotiated.deinit();
    try t.expectEqual(@as(usize, 4), negotiated.count);
    try t.expect(state.ready() and state.support().files and !state.support().monitors);
    const sent = try state.receive(.{ .request = 1 });
    defer sent.deinit();
    const parsed = (try p.decodeClipboard(1, 4, sent.items[0].send.data.bytes())).?;
    try t.expectEqualStrings("hello", parsed.data.bytes);
    const grab = try state.receive(.{ .grab = p.Types.utf8() });
    defer grab.deinit();
    try t.expectEqual(@as(u32, 8), grab.items[0].send.kind);
    const guest = try state.receive(.{ .data = .{ .kind = 1, .bytes = "guest" } });
    defer guest.deinit();
    try t.expectEqualStrings("guest", guest.items[0].write_guest.bytes());
    state.didWrite(2);
    const echo = try state.localChanged(2, "guest");
    defer echo.deinit();
    try t.expectEqual(@as(usize, 0), echo.count);
    const unavailable = state.disconnected();
    defer unavailable.deinit();
    try t.expectEqual(@as(usize, 1), unavailable.count);
    try t.expectEqualStrings("guest", guest.items[1].emit.guest_text.bytes());
}
test "Clipboard demand-only negotiation send confirmation owned actions and every allocation failure" {
    try t.checkAllAllocationFailures(t.allocator, clipboardLifecycle, .{});
}
test "Clipboard disabled policy rejection consumes request" {
    var state = s.clipboard.State.init(t.allocator, 2, false);
    defer state.deinit();
    try t.expectError(error.AgentDisconnected, state.receive(.release));
    (try state.connected()).deinit();
    (try state.receive(.{ .capabilities = .{ .reply = false, .values = p.Capabilities.desktop(true) } })).deinit();
    try t.expect(!state.ready());
    (try state.receive(.{ .data = .{ .kind = 1, .bytes = "unsolicited" } })).deinit();
    (try state.setEnabled(true)).deinit();
    try t.expect(state.ready());
    for (0..3) |mode| {
        (try state.receive(.{ .grab = p.Types.utf8() })).deinit();
        switch (mode) {
            0 => try t.expectError(error.UnexpectedClipboardType, state.receive(.{ .data = .{ .kind = 9, .bytes = "x" } })),
            1 => try t.expectError(error.OversizedGuestText, state.receive(.{ .data = .{ .kind = 1, .bytes = "big" } })),
            else => try t.expectError(error.InvalidUTF8, state.receive(.{ .data = .{ .kind = 1, .bytes = &.{255} } })),
        }
        try t.expectError(error.UnsolicitedClipboardData, state.receive(.{ .data = .{ .kind = 1, .bytes = "ok" } }));
    }
    (try state.localChanged(3, "ok")).deinit();
    const oversized = try state.localChanged(4, "big");
    defer oversized.deinit();
    try t.expectEqual(@as(usize, 2), oversized.count);
    try t.expectEqual(@as(u32, 9), oversized.items[0].send.kind);
    (try state.localChanged(5, "ok")).deinit();
    const disabled = try state.setEnabled(false);
    defer disabled.deinit();
    try t.expectEqual(@as(usize, 3), disabled.count);
    try t.expectEqual(@as(u32, 9), disabled.items[0].send.kind);
}
fn encodings(a: std.mem.Allocator) !void {
    const start = try p.encodeFileStart(a, 9, "报告.txt", 123, .{});
    defer start.deinit();
    const value = (try p.decodeFile(1, start.kind, start.data.bytes(), .{})).?;
    try t.expectEqualStrings("[vdagent-file-xfer]\nname=报告.txt\nsize=123\n\x00", value.start.metadata);
    const bytes = try p.encodeFileData(a, 9, &.{ 0, 255, 3 }, .{});
    defer bytes.deinit();
    const data = (try p.decodeFile(1, 12, bytes.data.bytes(), .{})).?;
    try t.expectEqualSlices(u8, &.{ 0, 255, 3 }, data.data.bytes);
    const status = try p.encodeFileStatus(a, 9, .success);
    defer status.deinit();
    try t.expectEqual(p.FileResult.success, (try p.decodeFile(1, 11, status.data.bytes(), .{})).?.status.result);
    const monitors = try p.encodeMonitors(a, &.{ .{ .width = 1024, .height = 768, .depth = 32, .x = -20, .y = 50 }, .{ .width = 0, .height = 0, .depth = 0 } }, true, true);
    defer monitors.deinit();
    try t.expectEqual(@as(usize, 48), monitors.data.bytes().len);
    const cap = try p.encodeClipboard(a, .{ .capabilities = .{ .reply = true, .values = p.Capabilities.desktop(true) } }, 42);
    defer cap.deinit();
    try t.expectEqual(@as(u64, 42), cap.opaque_id);
}
test "Agent desktop encodings all allocation failures and exact file metadata" {
    try t.checkAllAllocationFailures(t.allocator, encodings, .{});
}
test "Agent limits Unicode basename and status detail rejection" {
    for ([_][]const u8{ "", ".", "..", "../x", "a\\b", " x", "x\u{2003}", "\u{85}x", "a\x00b", "\xff" }) |name| {
        if (p.encodeFileStart(t.allocator, 1, name, 0, .{})) |v| {
            v.deinit();
            return error.AcceptedUnsafeName;
        } else |_| {}
    }
    const safe = try p.encodeFileStart(t.allocator, 1, "a b", 0, .{});
    safe.deinit();
    try t.expectError(error.InvalidSize, p.decodeClipboard(1, 7, &.{}));
    try t.expectEqual(@as(?p.Clipboard, null), try p.decodeClipboard(2, 7, &.{}));
    const status = (try p.decodeFile(1, 11, &.{ 1, 0, 0, 0, 2, 0, 0, 0, 0, 23, 0, 0, 0 }, .{})).?;
    try t.expectEqual(@as(u32, 23), status.status.detail.?.glib_io);
    try t.expectError(error.TrailingBytes, p.decodeFile(1, 11, &.{ 1, 0, 0, 0, 3, 0, 0, 0, 0 }, .{}));
    try t.expectEqual(@as(?bool, null), try p.decodeMonitorReply(1, 3, &.{ 7, 0, 0, 0, 255, 0, 0, 0 }));
    try t.expectError(error.InvalidEnum, p.decodeMonitorReply(1, 3, &.{ 2, 0, 0, 0, 255, 0, 0, 0 }));
    try t.expectError(error.InvalidSize, p.encodeMonitors(t.allocator, &.{.{ .width = 1, .height = 0, .depth = 32 }}, false, true));
}

fn support() s.clipboard.Support {
    return .{ .connected = true, .explicit = true, .monitors = true, .sparse = true, .positions = true, .file_state = true, .files = true, .detailed_errors = true };
}
extern "c" fn mkstemp([*:0]u8) c_int;
fn temporary(a: std.mem.Allocator, bytes: []const u8) !*s.file_source.Source {
    var path = [_]u8{ '/', 't', 'm', 'p', '/', 's', 'p', 'i', 'c', 'e', '-', 'z', 'i', 'g', '-', 'X', 'X', 'X', 'X', 'X', 'X', 0 };
    const fd = mkstemp(path[0 .. path.len - 1 :0]);
    if (fd < 0) return error.TestFileOpen;
    _ = std.c.unlink(path[0 .. path.len - 1 :0]);
    if (std.c.write(fd, bytes.ptr, bytes.len) != bytes.len) {
        _ = std.c.close(fd);
        return error.TestFileWrite;
    }
    return s.file_source.Source.adopt(a, fd);
}
fn upload(a: std.mem.Allocator) !void {
    const file = try temporary(a, "abcdefgh");
    defer file.release();
    var state = s.file_transfer.State.init(a, .{ .chunk = 3 });
    defer state.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const queued = try state.queue(file, "file.txt", support());
    defer queued.deinit();
    const key = queued.queued.key;
    const start = try state.prepare(key, support());
    defer start.deinit();
    try t.expectEqual(@as(u32, 10), start.send.message.kind);
    try t.expectEqual(@as(?s.file_transfer.Event, null), try state.completeSend(start.send, false));
    try t.expectEqual(s.file_transfer.Phase.queued_start, state.phase(key).?);
    (try state.completeSend(start.send, true)).?.deinit();
    try t.expectEqual(@as(?s.file_transfer.Event, null), try state.receive(.{ .id = key.id, .result = .can_send }));
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    while (state.phase(key) != .awaiting_completion) {
        const read = try state.prepare(key, support());
        defer read.deinit();
        try t.expectEqual(s.file_transfer.Phase.reading, state.phase(key).?);
        const data = try read.read.run(a, &token); // allocation failure remains visible to the harness
        try state.completeRead(read.read, data);
        const send = try state.prepare(key, support());
        defer send.deinit();
        const parsed = (try p.decodeFile(1, 12, send.send.message.data.bytes(), .{})).?;
        try output.appendSlice(a, parsed.data.bytes);
        const event = (try state.completeSend(send.send, true)).?;
        defer event.deinit();
        try t.expectEqual(@as(u64, output.items.len), event.progress.sent);
    }
    try t.expectEqualStrings("abcdefgh", output.items);
    const complete = (try state.receive(.{ .id = key.id, .result = .success })).?;
    defer complete.deinit();
    try t.expectEqual(key, complete.completed);
    try t.expectEqual(@as(usize, 0), state.count());
}
test "File upload retained descriptor bounded chunks token admission and every allocation failure" {
    try t.checkAllAllocationFailures(t.allocator, upload, .{});
}
test "File upload cancellation invalid statuses stale read after removal and truncation" {
    const a = t.allocator;
    const file = try temporary(a, "abcdef");
    defer file.release();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var state = s.file_transfer.State.init(a, .{ .concurrent = 1, .chunk = 3 });
    defer state.deinit();
    const q = try state.queue(file, "file", support());
    defer q.deinit();
    const key = q.queued.key;
    try t.expectError(error.TooManyFileTransfers, state.queue(file, "file", support()));
    const start = try state.prepare(key, support());
    defer start.deinit();
    (try state.completeSend(start.send, true)).?.deinit();
    _ = try state.receive(.{ .id = key.id, .result = .can_send });
    const read = try state.prepare(key, support());
    defer read.deinit();
    _ = try state.cancelTransfer(key);
    try state.completeRead(read.read, try read.read.run(a, &token));
    try t.expectEqual(s.file_transfer.Phase.queued_cancel, state.phase(key).?);
    const cancellation = try state.prepare(key, support());
    defer cancellation.deinit();
    _ = try state.completeSend(cancellation.send, true);
    (try state.receive(.{ .id = key.id, .result = .cancelled })).?.deinit();
    // An owned read ticket still works after job removal, but cannot reinsert it.
    try state.completeRead(read.read, try read.read.run(a, &token));
    try t.expectEqual(@as(usize, 0), state.count());
    const q2 = try state.queue(file, "file", support());
    defer q2.deinit();
    const early = (try state.receive(.{ .id = q2.queued.key.id, .result = .success })).?;
    defer early.deinit();
    try t.expectEqual(error.PrematureFileSuccess, early.failed.reason);
    const q3 = try state.queue(file, "file", support());
    defer q3.deinit();
    const start3 = try state.prepare(q3.queued.key, support());
    defer start3.deinit();
    (try state.completeSend(start3.send, true)).?.deinit();
    _ = try state.receive(.{ .id = q3.queued.key.id, .result = .can_send });
    const read3 = try state.prepare(q3.queued.key, support());
    defer read3.deinit();
    try t.expectEqual(@as(c_int, 0), std.c.ftruncate(file.fd, 1));
    try state.completeRead(read3.read, read3.read.run(a, &token));
    const failure = try state.prepare(q3.queued.key, support());
    defer failure.deinit();
    try t.expectEqual(@as(u32, 11), failure.send.message.kind);
    const failed = (try state.completeSend(failure.send, true)).?;
    defer failed.deinit();
    try t.expectEqual(error.FileTruncated, failed.failed.reason);
}
test "Monitor sparse layout capability checks and pending newest survives disconnect" {
    const configuration = try s.monitor_config.Configuration.init(&.{ .{ .id = 2, .width = 1920, .height = 1080, .x = -100 }, .{ .id = 0, .width = 800, .height = 600 } });
    const encoded = try configuration.encode(support());
    try t.expect(encoded.sparse and encoded.positions);
    try t.expectEqual(@as(usize, 3), encoded.count);
    try t.expectEqual(@as(u32, 0), encoded.monitors[1].width);
    try t.expectEqual(@as(i32, -100), encoded.monitors[2].x);
    var unsupported = support();
    unsupported.sparse = false;
    try t.expectError(error.UnsupportedMonitorConfiguration, configuration.encode(unsupported));
    unsupported.explicit = false;
    _ = try configuration.encode(unsupported);
    const duplicate = try s.monitor_config.Configuration.init(&.{ .{ .id = 0, .width = 1, .height = 1 }, .{ .id = 0, .width = 1, .height = 1 } });
    try t.expectError(error.InvalidLayout, duplicate.encode(support()));
    var coordinator: s.monitor_config.Coordinator = .{};
    const first = try coordinator.queue(configuration);
    try t.expect(coordinator.didSend(first.id));
    const next = try coordinator.queue(try s.monitor_config.Configuration.init(&.{.{ .id = 0, .width = 640, .height = 480 }}));
    try t.expectEqual(@as(?s.monitor_config.Request, null), coordinator.next());
    coordinator.disconnected();
    try t.expectEqual(next.id, coordinator.next().?.id);
    try t.expect(!coordinator.didSend(first.id));
    try t.expect(coordinator.didSend(next.id));
    try t.expectEqual(next.id, coordinator.reply().?.id);
    try t.expectEqual(@as(?s.monitor_config.Request, null), coordinator.reply());
}

const ManagerHost = struct {
    blocked: bool = false,
    fail_send: bool = false,
    fail_write: bool = false,
    writes: usize = 0,
    sent: std.ArrayList(s.agent.Message) = .empty,
    generations: std.ArrayList(u64) = .empty,
    events: std.ArrayList(s.agent_manager.Event) = .empty,
    fn host(self: *ManagerHost) s.agent_manager.Host {
        return .{ .context = self, .send = send, .write_text = writeText, .emit = emit };
    }
    fn send(ctx: *anyopaque, generation: u64, message: s.agent.Message, token: *s.cancel.Token) !bool {
        const self: *ManagerHost = @ptrCast(@alignCast(ctx));
        try token.check();
        if (self.fail_send) return error.InjectedTransportFailure;
        if (self.blocked) return false;
        try self.sent.append(t.allocator, .{ .protocol = message.protocol, .kind = message.kind, .opaque_id = message.opaque_id, .data = message.data.clone() });
        try self.generations.append(t.allocator, generation);
        return true;
    }
    fn writeText(ctx: *anyopaque, _: []const u8, token: *s.cancel.Token) !i64 {
        const self: *ManagerHost = @ptrCast(@alignCast(ctx));
        try token.check();
        if (self.fail_write) return error.InjectedPasteboardFailure;
        self.writes += 1;
        return @intCast(self.writes);
    }
    fn emit(ctx: *anyopaque, event: s.agent_manager.Event) void {
        const self: *ManagerHost = @ptrCast(@alignCast(ctx));
        self.events.append(t.allocator, event) catch @panic("test event allocation");
    }
    fn deinit(self: *ManagerHost) void {
        for (self.sent.items) |m| m.deinit();
        self.sent.deinit(t.allocator);
        self.generations.deinit(t.allocator);
        for (self.events.items) |e| e.deinit();
        self.events.deinit(t.allocator);
    }
};
fn capabilities(manager: *s.agent_manager.Manager, generation: u64) !void {
    const m = try p.encodeClipboard(t.allocator, .{ .capabilities = .{ .reply = true, .values = p.Capabilities.desktop(true) } }, 0);
    defer m.deinit();
    try manager.receive(generation, 1, m.kind, m.data.bytes());
}
fn untilIdle(manager: *s.agent_manager.Manager, token: *s.cancel.Token) !void {
    for (0..64) |_| {
        if (try manager.pump(token, 4) != .more) return;
    }
    return error.ManagerDidNotQuiesce;
}
test "Agent manager backpressure bounded turns layout replies file upload migration and owned events" {
    var host: ManagerHost = .{ .blocked = true };
    defer host.deinit();
    var manager = s.agent_manager.Manager.init(t.allocator, host.host(), .{ .file_limits = .{ .chunk = 3 } });
    defer manager.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try manager.connect(1);
    try manager.localChanged(2, "hello");
    try manager.requestDisplay(try s.monitor_config.Configuration.init(&.{.{ .id = 0, .width = 640, .height = 480 }}));
    try t.expectEqual(s.agent_manager.Pump.blocked, try manager.pump(&token, 8));
    try t.expectEqual(@as(usize, 0), host.sent.items.len);
    host.blocked = false;
    try untilIdle(&manager, &token);
    try t.expectEqual(@as(u32, 6), host.sent.items[0].kind);
    try t.expectEqual(@as(u32, 2), host.sent.items[1].kind);
    try capabilities(&manager, 1);
    try manager.receive(1, 1, 3, &.{ 2, 0, 0, 0, 1, 0, 0, 0 });
    try untilIdle(&manager, &token);
    const file = try temporary(t.allocator, "upload-bytes");
    defer file.release();
    const key = try manager.queueFile(
        file,
        "fixture",
    );
    try untilIdle(&manager, &token);
    try t.expectEqual(s.file_transfer.Phase.awaiting_approval, manager.transfers.phase(key).?);
    const approval = try p.encodeFileStatus(t.allocator, key.id, .can_send);
    defer approval.deinit();
    try manager.receive(1, 1, 11, approval.data.bytes());
    try manager.adoptGeneration(1, 2);
    try t.expectError(error.StaleAgentGeneration, manager.receive(1, 1, 9, &.{}));
    try untilIdle(&manager, &token);
    try t.expectEqual(s.file_transfer.Phase.awaiting_completion, manager.transfers.phase(key).?);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(t.allocator);
    for (host.sent.items, host.generations.items) |message, generation| if (message.kind == 12) {
        try t.expectEqual(@as(u64, 2), generation);
        const data = (try p.decodeFile(1, 12, message.data.bytes(), .{})).?.data.bytes;
        try bytes.appendSlice(t.allocator, data);
    };
    try t.expectEqualStrings("upload-bytes", bytes.items);
    const completed = try p.encodeFileStatus(t.allocator, key.id, .success);
    defer completed.deinit();
    try manager.receive(2, 1, 11, completed.data.bytes());
    try t.expectEqual(@as(usize, 0), manager.transfers.count());
    manager.disconnect();
    var saw_complete = false;
    for (host.events.items) |event| if (event == .file and event.file == .completed) {
        saw_complete = true;
    };
    try t.expect(saw_complete);
}
test "Agent manager revokes pending failed host writes and never retries uncertain transport sends" {
    var host: ManagerHost = .{ .fail_write = true };
    defer host.deinit();
    var manager = s.agent_manager.Manager.init(t.allocator, host.host(), .{});
    defer manager.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try manager.connect(1);
    try capabilities(&manager, 1);
    try untilIdle(&manager, &token);
    try manager.receive(1, 1, 7, &.{ 1, 0, 0, 0 });
    try untilIdle(&manager, &token);
    try manager.receive(1, 1, 4, &.{ 1, 0, 0, 0, 'x' });
    try t.expectError(error.InjectedPasteboardFailure, manager.pump(&token, 8));
    try t.expect(manager.pending_count > 0);
    try manager.setClipboardEnabled(false);
    host.fail_write = false;
    try untilIdle(&manager, &token);
    try t.expectEqual(@as(usize, 0), host.writes);
    const sent = host.sent.items.len;
    try manager.setClipboardEnabled(true);
    host.fail_send = true;
    try t.expectError(error.InjectedTransportFailure, manager.pump(&token, 8));
    host.fail_send = false;
    try t.expectEqual(s.agent_manager.Pump.idle, try manager.pump(&token, 8));
    try t.expectEqual(sent, host.sent.items.len);
    try t.expectEqual(@as(?u64, null), manager.generation);
}

const BoundRuntime = struct {
    const Boot = struct { agent_epoch: u64 = 1, agent_connected: bool = true };
    const Group = struct { bootstrap: ?Boot = Boot{} };
    pub const Event = s.supervisor.Supervisor(s.desktop_child).Event;
    mutex: s.sync.Mutex = .{},
    phase: enum { ready } = .ready,
    stopping: bool = false,
    active: ?*Group,
    lifecycle: u64 = 1,
    sends: usize = 0,
    pub fn sendAgentAt(self: *BoundRuntime, epoch: s.supervisor.AgentEpoch, _: u32, _: u32, _: u64, _: []const u8, token: *s.cancel.Token) anyerror!bool {
        try token.check();
        try t.expectEqual(@as(u64, 1), epoch.session);
        try t.expectEqual(@as(u64, 1), epoch.agent);
        self.sends += 1;
        return true;
    }
};
fn bindingAllocations(a: std.mem.Allocator) !void {
    var group: BoundRuntime.Group = .{};
    var runtime: BoundRuntime = .{ .active = &group };
    defer runtime.mutex.deinit();
    var host: ManagerHost = .{};
    defer host.deinit();
    const binding = try s.agent_session.Binding(BoundRuntime).create(a, &runtime, .{ .context = &host, .write_text = ManagerHost.writeText, .emit = ManagerHost.emit }, .{});
    defer binding.destroy();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try untilIdle(&binding.manager, &token);
    try t.expectEqual(@as(usize, 1), runtime.sends);
}
test "Agent binding creation cleans every allocation failure and pending-byte overflow retires epoch" {
    try t.checkAllAllocationFailures(t.allocator, bindingAllocations, .{});
    var host: ManagerHost = .{};
    defer host.deinit();
    var manager = s.agent_manager.Manager.init(t.allocator, host.host(), .{ .pending_bytes = 7 });
    defer manager.deinit();
    try t.expectError(error.AgentWorkQueueFull, manager.connect(1));
    try t.expect(!manager.state.agent_connected and manager.pending_count == 0);
}
