const std = @import("std");
const t = std.testing;
const s = @import("spice");
const Fixture = @import("webdav_test_support.zig").Fixture;
fn exercise(a: std.mem.Allocator, path: []const u8) !void {
    const server = try s.webdav_server.Server.create(a, path, false, .{});
    var released = false;
    defer if (!released) server.release();
    var partial = try server.receive(1, "GET /file HTTP/1.1\r\n");
    defer partial.deinit();
    try t.expectEqual(0, partial.items.items.len);
    var responses = try server.receive(1, "\r\nHEAD /file HTTP/1.1\r\n\r\n");
    defer responses.deinit();
    server.release();
    released = true;
    try t.expectEqual(2, responses.items.items.len);
    try t.expect(std.mem.endsWith(u8, responses.items.items[0], "\r\n\r\nhello"));
    try t.expect(std.mem.endsWith(u8, responses.items.items[1], "\r\n\r\n"));
}
test "WebDAV shared server owns compatibility responses after release and frees every failed allocation" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.file("file", "hello");
    const path = std.mem.span(@as([*:0]const u8, &fixture.path));
    try exercise(t.allocator, path);
    try t.checkAllAllocationFailures(t.allocator, exercise, .{path});
}
