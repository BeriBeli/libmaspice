const std = @import("std");
const t = std.testing;
const s = @import("spice");
const a = t.allocator;
fn target(host: []const u8) s.migration.Destination {
    return .{ .host = host, .port = 5900, .secure_port = 5901, .subject = null };
}
test "migration newer offers cancel old work and fence late success failure and handoff" {
    var c: s.migration_coordinator.Coordinator = .{ .allocator = a };
    defer c.deinit();
    const first = try c.receive(.{ .begin = target("first") });
    defer first.deinit();
    const id = first.items()[1].prepare.id;
    const second = try c.receive(.{ .begin_seamless = .{ .destination = target("second"), .source_version = 9 } });
    defer second.deinit();
    try t.expectEqual(@as(usize, 4), second.len);
    try t.expectEqual(id, second.items()[1].cancel.id);
    const active = second.items()[3].prepare.id;
    try t.expect(active != id);
    var late = c.prepared(id, false);
    defer late.deinit();
    try t.expectEqual(@as(usize, 0), late.len);
    const ready = c.prepared(active, true);
    defer ready.deinit();
    try t.expect(ready.items()[0].event.seamless);
    try t.expect(ready.items()[1].send == .connected_seamless);
    const invalid = try c.receive(.end);
    defer invalid.deinit();
    try t.expect(invalid.items()[0] == .violation);
    const commit = c.seamlessCommit(active);
    defer commit.deinit();
    try t.expectEqual(s.migration_coordinator.Phase.committing, c.phase);
    const finished = c.finished(active, null);
    defer finished.deinit();
    try t.expectEqual(s.migration_coordinator.EventKind.completed, finished.items()[0].event.kind);
    try t.expectEqual(s.migration_coordinator.Phase.idle, c.phase);
    try t.expectEqualSlices(u8, "first", first.items()[1].prepare.destination.host);
}
test "semi-seamless end, cancellation, switch-host and preparation failure preserve action order" {
    var c: s.migration_coordinator.Coordinator = .{ .allocator = a };
    defer c.deinit();
    const initial = try c.receive(.end);
    defer initial.deinit();
    try t.expect(initial.items()[0] == .violation);
    const begin = try c.receive(.{ .begin = target("target") });
    defer begin.deinit();
    const id = begin.items()[1].prepare.id;
    const ready = c.prepared(id, true);
    defer ready.deinit();
    try t.expect(!ready.items()[0].event.seamless);
    const end = try c.receive(.end);
    defer end.deinit();
    try t.expect(end.items()[1] == .commit);
    const switched = try c.receive(.{ .switch_host = target("switch") });
    defer switched.deinit();
    try t.expectEqual(@as(usize, 4), switched.len);
    try t.expect(switched.items()[3] == .switch_host);
    const cancelled = try c.receive(.cancel);
    defer cancelled.deinit();
    try t.expectEqual(@as(usize, 2), cancelled.len);
    const new = try c.receive(.{ .begin = target("failure") });
    defer new.deinit();
    const failed = c.preparationFailed(new.items()[1].prepare.id, error.TLSFailure);
    defer failed.deinit();
    try t.expect(failed.items()[1].send == .connect_error);
    const late = c.finished(id, error.ConnectionClosed);
    defer late.deinit();
    try t.expectEqual(@as(usize, 0), late.len);
}
test "migration trust inherits CA/name policy refuses downgrade and subject offers" {
    const current: s.endpoint.Config = .{ .host = "source", .port = 5901, .tls = .{ .kind = .custom_ca, .server_name = "pinned.name", .certificates = &.{"public certificate"} }, .timeout_ms = 500 };
    const selected = try s.endpoint.destination(current, target("target"));
    try t.expectEqual(@as(u16, 5901), selected.port);
    try t.expectEqualSlices(u8, "pinned.name", selected.tls.server_name.?);
    try t.expectEqual(@as(u32, 500), selected.timeout_ms);
    var offer = target("target");
    offer.secure_port = 0;
    try t.expectError(error.TLSDowngrade, s.endpoint.destination(current, offer));
    offer.subject = "CN=target";
    try t.expectError(error.UnsupportedMigrationSubject, s.endpoint.destination(current, offer));
    offer = target("target");
    offer.port = 0;
    const upgraded = try s.endpoint.destination(.{ .host = "source", .port = 5900 }, offer);
    try t.expectEqual(s.transport.tls.Kind.system, upgraded.tls.kind);
}
test "child inventory rejects duplicates before connection, preserves order and excludes only exact Main key" {
    const main: s.barrier.Key = .{ .kind = 1, .id = 0 };
    const keys = [_]s.barrier.Key{ .{ .kind = 3, .id = 2 }, main, .{ .kind = 2, .id = 1 }, .{ .kind = 1, .id = 4 } };
    const requests = try s.child_connections.validate(a, &keys, main, 4);
    defer a.free(requests);
    try t.expectEqual(@as(usize, 3), requests.len);
    try t.expectEqual(@as(u8, 3), requests[0].kind);
    try t.expectEqual(@as(u8, 4), requests[2].id);
    try t.expectError(error.DuplicateChannel, s.child_connections.validate(a, &.{ main, main }, main, 4));
    try t.expectError(error.TooManyChannels, s.child_connections.validate(a, &keys, main, 3));
    try t.expectEqual(@as(u32, 13), s.child_connections.capabilities(main, .mjpeg, null));
    try t.expectEqual(@as(u32, 5), s.child_connections.capabilities(main, .mjpeg, false));
    try t.expectEqual(@as(u32, 787), s.child_connections.capabilities(.{ .kind = 2, .id = 0 }, .mjpeg, null));
}
fn allocationRun(allocator: std.mem.Allocator) !void {
    const endpoint = try s.endpoint.Owned.init(allocator, .{ .host = "host", .port = 5900, .tls = .{ .server_name = "server", .expected_subject = "subject", .certificates = &.{ "one", "two" } } });
    defer endpoint.deinit();
    var c: s.migration_coordinator.Coordinator = .{ .allocator = allocator };
    defer c.deinit();
    const first = try c.receive(.{ .begin = target("first") });
    defer first.deinit();
    const second = try c.receive(.{ .begin = target("second") });
    defer second.deinit();
}
test "endpoint and migration offer allocation failures release all owned policy and destination storage" {
    try t.checkAllAllocationFailures(a, allocationRun, .{});
}
