const std = @import("std");
const t = std.testing;
const s = @import("spice");
const a = t.allocator;
extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
pub const Fixture = struct {
    path: [64:0]u8 = @splat(0),
    root: s.webdav_path.Root,
    pub fn init() !Fixture {
        var path: [64:0]u8 = @splat(0);
        const template = "/tmp/spicezig-webdav-XXXXXX";
        @memcpy(path[0..template.len], template);
        const name = mkdtemp(&path) orelse return error.CreateFailed;
        errdefer _ = std.c.rmdir(name);
        return .{ .path = path, .root = try s.webdav_path.Root.open(a, std.mem.span(name)) };
    }
    pub fn deinit(self: *Fixture) void {
        for ([_][*:0]const u8{ "link", "escape", "file", "sub/file", "held/file" }) |name| {
            _ = std.c.unlinkat(self.root.fd, name, 0);
        }
        for ([_][*:0]const u8{ "sub", "held" }) |name| {
            _ = std.c.unlinkat(self.root.fd, name, 0);
            _ = std.c.unlinkat(self.root.fd, name, std.c.AT.REMOVEDIR);
        }
        self.root.deinit();
        _ = std.c.rmdir(&self.path);
    }
    pub fn file(self: *Fixture, name: [*:0]const u8, bytes: []const u8) !void {
        const fd = std.c.openat(self.root.fd, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(c_uint, 0o600));
        if (fd < 0) return error.CreateFailed;
        defer _ = std.c.close(fd);
        try t.expectEqual(@as(isize, @intCast(bytes.len)), std.c.write(fd, bytes.ptr, bytes.len));
    }
};
