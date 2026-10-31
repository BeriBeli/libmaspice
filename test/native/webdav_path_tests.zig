const std = @import("std");
const t = std.testing;
const s = @import("spice");
const a = t.allocator;
const Fixture = @import("webdav_test_support.zig").Fixture;
test "WebDAV root path URL decoding traversal and UTF8 validation" {
    var f = try Fixture.init();
    defer f.deinit();
    for ([_][]const u8{ "/a/../file", "/%2e%2e/file", "/./file" }) |target| try t.expectError(error.PathEscapesRoot, f.root.resolve(target));
    for ([_][]const u8{ "relative", "/%00", "/%7F", "/%GG", "/\xff" }) |target| try t.expectError(error.InvalidRequest, f.root.resolve(target));
    for ([_][]const u8{ "/file?query", "http://host/file?q#frag", "//file", "?/file?query" }) |target| {
        const entry = try f.root.resolve(target);
        defer entry.deinit();
        try t.expectEqualStrings("file", entry.name);
        try t.expectEqual(null, try entry.stat());
    }
    const root = try f.root.resolve("/");
    defer root.deinit();
    try t.expect(root.is_root);
    try t.expectEqualStrings("", root.canonical);
}
test "WebDAV internal symbolic links retain leaf identity and cannot escape authorized root" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("file", "inside");
    try t.expectEqual(0, std.c.symlinkat("file", f.root.fd, "link"));
    try t.expectEqual(0, std.c.symlinkat("/etc/passwd", f.root.fd, "escape"));
    const entry = try f.root.resolve("/link");
    defer entry.deinit();
    try t.expectEqualStrings("link", entry.name);
    try t.expectEqualStrings("file", entry.canonical);
    try t.expectEqual(std.c.S.IFLNK, (try entry.stat()).?.mode & std.c.S.IFMT);
    const fd = try f.root.openResolved(entry);
    defer _ = std.c.close(fd);
    var bytes: [6]u8 = undefined;
    try t.expectEqual(6, std.c.read(fd, &bytes, 6));
    try t.expectEqualStrings("inside", &bytes);
    try t.expectError(error.PathEscapesRoot, f.root.resolve("/escape"));
}
test "WebDAV checked path cannot be redirected by replacing a canonical directory with symlink" {
    var f = try Fixture.init();
    defer f.deinit();
    try t.expectEqual(0, std.c.mkdirat(f.root.fd, "sub", 0o700));
    try f.file("sub/file", "inside");
    const entry = try f.root.resolve("/sub/file");
    defer entry.deinit();
    try t.expectEqual(0, std.c.renameat(f.root.fd, "sub", f.root.fd, "held"));
    try t.expectEqual(0, std.c.symlinkat("/tmp", f.root.fd, "sub"));
    try t.expectError(error.NotFound, f.root.openResolved(entry));
}
fn allocated(allocator: std.mem.Allocator, path: []const u8) !void {
    const root = try s.webdav_path.Root.open(allocator, path);
    defer root.deinit();
    const entry = try root.resolve("http://host/file%20name?query");
    defer entry.deinit();
    try t.expectEqualStrings("file name", entry.name);
}
test "WebDAV root and URL path allocation failures close all owned descriptors" {
    var f = try Fixture.init();
    defer f.deinit();
    try t.checkAllAllocationFailures(a, allocated, .{std.mem.span(@as([*:0]const u8, &f.path))});
}
