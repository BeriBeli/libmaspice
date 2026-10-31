const std = @import("std");
const s = @import("spice");
const a = std.heap.c_allocator;
pub export fn webdav_fs_execute(root: [*:0]const u8, write: u8, limit: usize, input: [*]const u8, length: usize, output: *?[*]u8, size: *usize) c_int {
    output.* = null;
    size.* = 0;
    const fs = s.webdav_fs.Filesystem.open(a, std.mem.span(root), write != 0, limit) catch return -9;
    defer fs.deinit();
    const parsed = s.webdav_http.next(a, input[0..length], 0, .{ .body_bytes = limit }) catch |err| return switch (err) {
        error.InvalidRequest => -1,
        error.HeaderTooLarge => -2,
        error.BodyTooLarge => -3,
        else => -99,
    };
    const request = parsed orelse return 0;
    defer request.deinit();
    const bytes = fs.execute(request) catch return -99;
    output.* = bytes.ptr;
    size.* = bytes.len;
    return 1;
}
pub export fn webdav_fs_free(output: [*]u8, size: usize) void {
    a.free(output[0..size]);
}
