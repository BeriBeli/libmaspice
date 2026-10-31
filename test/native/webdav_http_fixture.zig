const std = @import("std");
const s = @import("spice");
const a = std.heap.c_allocator;
fn less(_: void, lhs: s.webdav_http.Header, rhs: s.webdav_http.Header) bool {
    return std.mem.order(u8, lhs.key, rhs.key) == .lt;
}
pub export fn webdav_http_parse(input: [*]const u8, length: usize, header: usize, body: usize, sequence: u64, output: [*]u8, capacity: usize, metadata: [*]u64) c_int {
    const parsed = s.webdav_http.next(a, input[0..length], sequence, .{ .header_bytes = header, .body_bytes = body }) catch |err| return switch (err) {
        error.InvalidRequest => -1,
        error.HeaderTooLarge => -2,
        error.BodyTooLarge => -3,
        else => -99,
    };
    const r = parsed orelse return 0;
    defer r.deinit();
    var w: s.bytes.Writer = .{ .allocator = a, .limit = capacity };
    defer w.deinit();
    std.mem.sort(s.webdav_http.Header, r.headers, {}, less);
    for ([_][]const u8{ r.method, r.target, r.body }) |field| {
        w.write(u64, field.len) catch return -99;
        w.append(field) catch return -99;
    }
    for (r.headers) |h| for ([_][]const u8{ h.key, h.value }) |field| {
        w.write(u64, field.len) catch return -99;
        w.append(field) catch return -99;
    };
    @memcpy(output[0..w.bytes.items.len], w.bytes.items);
    metadata[0..6].* = .{ r.consumed, r.retained, r.response_limit, r.sequence, r.headers.len, w.bytes.items.len };
    return 1;
}
