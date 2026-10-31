const std = @import("std");
const t = std.testing;
const s = @import("spice");
const a = t.allocator;
const Fixture = @import("webdav_test_support.zig").Fixture;
fn run(fs: *const s.webdav_fs.Filesystem, method: []const u8, target: []const u8, headers: []const u8, body: []const u8) ![]u8 {
    const input = try std.fmt.allocPrint(a, "{s} {s} HTTP/1.1\r\nContent-Length: {d}\r\n{s}\r\n{s}", .{ method, target, body.len, headers, body });
    defer a.free(input);
    const request = (try s.webdav_http.next(a, input, 0, .{})).?;
    defer request.deinit();
    return fs.execute(request);
}
fn expect(fs: *const s.webdav_fs.Filesystem, method: []const u8, target: []const u8, headers: []const u8, body: []const u8, status: u16) !void {
    const output = try run(fs, method, target, headers, body);
    defer a.free(output);
    try t.expectEqual(status, try std.fmt.parseInt(u16, output[9..12], 10));
}
test "WebDAV readonly filesystem bounded GET HEAD PROPFIND and mutation rejection" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.file("file", "hello");
    var fs = try s.webdav_fs.Filesystem.open(a, std.mem.span(@as([*:0]const u8, &fixture.path)), false, 4096);
    defer fs.deinit();
    const get = try run(&fs, "GET", "/file", "", "");
    defer a.free(get);
    try t.expect(std.mem.endsWith(u8, get, "\r\n\r\nhello"));
    const head = try run(&fs, "HEAD", "/file", "", "");
    defer a.free(head);
    try t.expect(std.mem.endsWith(u8, head, "\r\n\r\n"));
    try t.expect(std.mem.indexOf(u8, head, "Content-Length: 5\r\n") != null);
    try expect(&fs, "GET", "/missing", "", "", 404);
    try expect(&fs, "GET", "/", "", "", 405);
    try expect(&fs, "PUT", "/file", "", "bad", 403);
    try expect(&fs, "GET", "/../escape", "", "", 403);
    try expect(&fs, "PROPFIND", "/", "", "", 403);
    const prop = try run(&fs, "PROPFIND", "/", "Depth: 1\r\n", "");
    defer a.free(prop);
    try t.expect(std.mem.indexOf(u8, prop, "<D:href>/file</D:href>") != null);
    fs.maximum_body = 4;
    try expect(&fs, "HEAD", "/file", "", "", 413);
    try expect(&fs, "PROPFIND", "/", "Depth: 0\r\n", "", 507);
}
test "WebDAV native file lifecycle preserves symlink PUT COPY DELETE behavior" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const fs = try s.webdav_fs.Filesystem.open(a, std.mem.span(@as([*:0]const u8, &fixture.path)), true, 4096);
    defer fs.deinit();
    try expect(&fs, "MKCOL", "/sub", "", "", 201);
    try expect(&fs, "PUT", "/sub/file", "", "hello", 201);
    try expect(&fs, "COPY", "/sub/file", "Destination: /file\r\n", "", 201);
    try expect(&fs, "COPY", "/sub/file", "Destination: /file\r\nOverwrite: f\r\n", "", 412);
    try expect(&fs, "MOVE", "/file", "Destination: /held\r\n", "", 201);
    try expect(&fs, "DELETE", "/held", "", "", 204);
    try t.expectEqual(0, std.c.symlinkat("sub/file", fixture.root.fd, "link"));
    try expect(&fs, "COPY", "/link", "Destination: /file\r\n", "", 201);
    var st: std.c.Stat = undefined;
    try t.expectEqual(0, std.c.fstatat(fixture.root.fd, "file", &st, std.c.AT.SYMLINK_NOFOLLOW));
    try t.expectEqual(std.c.S.IFLNK, st.mode & std.c.S.IFMT);
    try expect(&fs, "PUT", "/link", "", "NEW", 204);
    const unchanged = try run(&fs, "GET", "/sub/file", "", "");
    defer a.free(unchanged);
    try t.expect(std.mem.endsWith(u8, unchanged, "hello"));
    try expect(&fs, "DELETE", "/file", "", "", 204);
    try expect(&fs, "GET", "/sub/file", "", "", 200);
    try expect(&fs, "PUT", "/link", "", "again", 204); // Native existing-file metadata copy.
    try expect(&fs, "COPY", "/link", "Destination: /link\r\n", "", 409);
    try expect(&fs, "DELETE", "/sub", "", "", 204);
    try expect(&fs, "DELETE", "/", "", "", 403);
}
fn allocated(allocator: std.mem.Allocator, path: []const u8) !void {
    const fs = try s.webdav_fs.Filesystem.open(allocator, path, false, 4096);
    defer fs.deinit();
    const request = (try s.webdav_http.next(allocator, "PROPFIND / HTTP/1.1\r\nDepth: 1\r\n\r\n", 0, .{})).?;
    defer request.deinit();
    const result = try fs.execute(request);
    defer allocator.free(result);
}
test "WebDAV PROPFIND allocator failures retain no partial body or descriptor ownership" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.file("file", "hello");
    try t.checkAllAllocationFailures(a, allocated, .{std.mem.span(@as([*:0]const u8, &fixture.path))});
}
