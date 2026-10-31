const std = @import("std");
const s = @import("spice");
const t = std.testing;
const Sink = struct {
    allocator: std.mem.Allocator,
    bodies: std.ArrayList(s.bytes.Slice) = .empty,
    cancelled: bool = false,
    fail: bool = false,
    pub fn send(self: *Sink, kind: u16, bytes: []const u8) !void {
        try t.expectEqual(@as(u16, 101), kind);
        if (self.fail) return error.InjectedFailure;
        const copy = try s.bytes.Slice.copy(self.allocator, bytes);
        errdefer copy.release();
        try self.bodies.append(self.allocator, copy);
    }
    pub fn cancel(self: *Sink) void {
        self.cancelled = true;
    }
    fn deinit(self: *Sink) void {
        for (self.bodies.items) |body| body.release();
        self.bodies.deinit(self.allocator);
    }
};
fn smartcard(a: std.mem.Allocator) !void {
    var sink: Sink = .{ .allocator = a };
    defer sink.deinit();
    var state = s.smartcard.State.init(a);
    defer state.deinit();
    try state.send(&sink, .{ .kind = .reader_add, .reader = s.smartcard_wire.undefined_reader, .bytes = "reader" });
    try state.send(&sink, .{ .kind = .atr, .reader = 2, .bytes = &.{ 0x3b, 0 } });
    try t.expectEqual(@as(usize, 1), sink.bodies.items.len);
    const result = try state.apply(&sink, .{ .kind = .result, .reader = 2, .bytes = &.{ 0, 0, 0, 0 } });
    defer result.deinit();
    try t.expectEqual(s.smartcard_wire.Kind.reader_add, result.completed.request);
    try t.expectEqual(@as(usize, 2), sink.bodies.items.len);
    const second = try s.smartcard_wire.decode(sink.bodies.items[1].bytes());
    try t.expectEqual(s.smartcard_wire.Kind.atr, second.kind);
    const apdu = try state.apply(&sink, .{ .kind = .apdu, .reader = 2, .bytes = &.{ 1, 2, 3, 4 } });
    defer apdu.deinit();
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, apdu.apdu.data.bytes());
}
test "Smartcard ordered control queue results and all allocation failures" {
    try t.checkAllAllocationFailures(t.allocator, smartcard, .{});
}
test "Smartcard queue bounds unsolicited result version and failed drain cleanup" {
    var sink: Sink = .{ .allocator = t.allocator };
    defer sink.deinit();
    var state = s.smartcard.State.init(t.allocator);
    defer state.deinit();
    try t.expectError(error.UnsolicitedSmartcardResult, state.apply(&sink, .{ .kind = .result, .reader = 1, .bytes = &.{ 0, 0, 0, 0 } }));
    try t.expectError(error.UnsupportedSmartcardVersion, state.apply(&sink, .{ .kind = .initialize, .reader = s.smartcard_wire.undefined_reader, .bytes = &.{ 0x56, 0x53, 0x43, 0x44, 3, 0, 0, 0 } }));
    for (0..64) |_| try state.send(&sink, .{ .kind = .reader_remove, .reader = 1 });
    try t.expectError(error.SmartcardQueueFull, state.send(&sink, .{ .kind = .reader_remove, .reader = 1 }));
    sink.fail = true;
    try t.expectError(error.InjectedFailure, state.apply(&sink, .{ .kind = .result, .reader = 1, .bytes = &.{ 0, 0, 0, 0 } }));
    try t.expect(sink.cancelled);
    var fresh = s.smartcard.State.init(t.allocator);
    defer fresh.deinit();
    try t.expectError(error.InjectedFailure, fresh.send(&sink, .{ .kind = .reader_add, .reader = s.smartcard_wire.undefined_reader, .bytes = "reader" }));
}
const port = [_]u8{ 4, 0, 0, 0, 9, 0, 0, 0, 1, 'w', 'e', 'b', 0 };
const mux = [_]u8{ 7, 0, 0, 0, 0, 0, 0, 0, 4, 0, 1, 2, 3, 4, 255, 255, 255, 255, 255, 255, 255, 255, 0, 0 };
fn webdav(a: std.mem.Allocator) !void {
    var state = s.webdav.State.init(a);
    defer state.deinit();
    var sink: Sink = .{ .allocator = a };
    defer sink.deinit();
    const initial = (try state.handle(201, &port)).?;
    defer initial.deinit();
    try t.expectEqualSlices(u8, "web", initial.initialized.name.bytes());
    try t.expectEqual(@as(?s.webdav.Event, null), try state.handle(101, mux[0..5]));
    const event = (try state.handle(101, mux[5..])).?;
    defer event.deinit();
    try t.expectEqual(@as(i64, 7), event.request.client);
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, event.request.data.bytes());
    const closed = (try state.next()).?;
    defer closed.deinit();
    try t.expectEqual(@as(i64, -1), closed.closed);
    try state.send(&sink, 7, &.{ 1, 2, 3, 4 });
    try t.expectEqualSlices(u8, mux[0..14], sink.bodies.items[0].bytes());
    (try state.handle(202, &.{1})).?.deinit();
    try t.expectError(error.PortClosed, state.send(&sink, 7, &.{}));
    try t.expectError(error.PortClosed, state.handle(101, &mux));
}
test "WebDAV fragments multiplex closed clients response and ownership under every allocation failure" {
    try t.checkAllAllocationFailures(t.allocator, webdav, .{});
}
test "WebDAV every split point port framing and VMC bounds" {
    for (1..mux.len) |split| {
        var state = s.webdav.State.init(t.allocator);
        defer state.deinit();
        (try state.handle(201, &port)).?.deinit();
        var events: usize = 0;
        if (try state.handle(101, mux[0..split])) |event| {
            event.deinit();
            events += 1;
        }
        while (try state.next()) |event| {
            event.deinit();
            events += 1;
        }
        if (try state.handle(101, mux[split..])) |event| {
            event.deinit();
            events += 1;
        }
        while (try state.next()) |event| {
            event.deinit();
            events += 1;
        }
        try t.expectEqual(@as(usize, 2), events);
    }
    for (0..port.len) |end| {
        if (s.webdav.portInit(port[0..end])) |_| return error.AcceptedTruncation else |_| {}
    }
    try t.expectError(error.InvalidSize, s.vmc.validate(&.{}));
    try t.expectError(error.UnnegotiatedCompression, s.vmc.decode(t.allocator, 102, &.{1}));
}
