const std = @import("std");
const t = std.testing;
const h = @import("spice").webdav_http;
const a = t.allocator;
const request = "put /file HTTP/1.1\r\nContent-Length: +3\r\nX-Test: a\r\n\r\nabc";
fn allocated(allocator: std.mem.Allocator) !void {
    const parsed = (try h.next(allocator, request, 7, .{})).?;
    defer parsed.deinit();
    try t.expectEqualStrings("PUT", parsed.method);
    try t.expectEqualStrings("abc", parsed.body);
    try t.expectEqual(8, parsed.sequence);
    try t.expectEqual(request.len + 768, parsed.retained);
}
test "HTTP owned requests fragmentation pipeline exact limits and failed allocations" {
    try t.checkAllAllocationFailures(a, allocated, .{});
    for (0..request.len) |end| try t.expectEqual(null, try h.next(a, request[0..end], 0, .{}));
    const parsed = (try h.next(a, request ++ "HEAD / HTTP/1.0\r\n\r\n", 4, .{ .header_bytes = request.len - 3, .body_bytes = 3 })).?;
    defer parsed.deinit();
    try t.expectEqual(request.len, parsed.consumed);
    try t.expectEqual(4096, parsed.response_limit);
    try t.expectError(error.HeaderTooLarge, h.next(a, request, 0, .{ .header_bytes = request.len - 4 }));
    try t.expectError(error.BodyTooLarge, h.next(a, request, 0, .{ .body_bytes = 2 }));
    try t.expectError(error.InvalidRequest, h.next(a, request, std.math.maxInt(u64), .{}));
    try t.expectError(error.BodyTooLarge, h.next(a, request, 0, .{ .body_bytes = std.math.maxInt(usize) }));
}
test "HTTP duplicate canonical keys transfer encoding and signed decimal validation" {
    for ([_][]const u8{
        "Content-Length: 0\r\ncontent-length: 0",
        "é: a\r\ne\xcc\x81: b",
        "Transfer-Encoding: identity",
        "Content-Length: -1",
        "Content-Length: 0x10",
        "Content-Length: 1_0",
        "Content-Length: 9223372036854775808",
        " : value",
        "missing-colon",
        "X: \xff",
    }) |headers| {
        const input = try std.fmt.allocPrint(a, "GET / HTTP/1.1\r\n{s}\r\n\r\n", .{headers});
        defer a.free(input);
        try t.expectError(error.InvalidRequest, h.next(a, input, 0, .{}));
    }
    const valid = (try h.next(a, "gEt / HTTP/1.0\r\n\xc2\xa0Content-Length\t: -0\u{2003}\r\n\r\n", 0, .{})).?;
    defer valid.deinit();
    try t.expectEqualStrings("GET", valid.method);
    try t.expectEqualStrings("-0", valid.header("content-length").?);
    try t.expectEqual(64 * 1024 * 1024 + 4096, valid.response_limit);
}
test "HTTP HEAD omits body with declared size and stable generated header order" {
    const response: h.Response = .{ .status = 200, .body = "hello", .content_type = "application/octet-stream" };
    const output = try response.encode(a, false);
    defer a.free(output);
    try t.expectEqualStrings("HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nContent-Length: 5\r\nContent-Type: application/octet-stream\r\n\r\n", output);
}
