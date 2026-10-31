const std = @import("std");
const s = @import("spice");
const t = std.testing;
const Host = s.usb_host.Host;
extern fn spice_usbredir_host_create(usize) ?*anyopaque;
extern fn spice_usbredir_host_destroy(*anyopaque) void;
extern fn spice_usbredir_host_take_output(*anyopaque, [*]u8, usize) usize;
extern fn spice_usbredir_host_feed_guest(*anyopaque, [*]const u8, usize) c_int;
extern fn spice_usbredir_host_pump(*anyopaque, u32) c_int;
extern fn spice_usbredir_host_detach(*anyopaque) c_int;
extern fn spice_usb_test_timeval_size() usize;
extern fn spice_usb_test_timeval_usec_offset() usize;
fn compareOutput(host: *Host, oracle: *anyopaque) !void {
    var bytes: [1024]u8 = undefined;
    while (host.outputSize() != 0) {
        const chunk = host.peekOutput();
        try t.expect(chunk.len > 0 and chunk.len <= host.options.maximum_packet_bytes);
        const n = spice_usbredir_host_take_output(oracle, &bytes, chunk.len);
        try t.expectEqualSlices(u8, chunk, bytes[0..n]);
        host.consumeOutput(chunk.len);
    }
    try t.expectEqual(@as(usize, 0), spice_usbredir_host_take_output(oracle, &bytes, bytes.len));
}
test "native hello and responses match unchanged C backend with fragmented guest input" {
    try t.expectEqual(@sizeOf(std.c.timeval), spice_usb_test_timeval_size());
    try t.expectEqual(@offsetOf(std.c.timeval, "usec"), spice_usb_test_timeval_usec_offset());
    for ([_]usize{ 1, 8, 4096 }) |packet_size| {
        const host = try Host.create(t.allocator, .{ .maximum_buffered_bytes = 4096, .maximum_packet_bytes = packet_size });
        defer host.destroy();
        const oracle = spice_usbredir_host_create(4096) orelse return error.OracleUnavailable;
        defer spice_usbredir_host_destroy(oracle);
        const hello = try t.allocator.dupe(u8, host.output[host.output_offset..]);
        defer t.allocator.free(hello);
        try t.expect(hello.len > 32);
        try compareOutput(host, oracle);
        // Symmetric hello/capability negotiation; all native calls use no device.
        for (hello) |byte| {
            const one = [_]u8{byte};
            const rc = spice_usbredir_host_feed_guest(oracle, &one, 1);
            host.receive(&one) catch |err| {
                try t.expectEqual(error.USBBackendFailure, err);
                try t.expectEqual(rc, host.backend_code);
                continue;
            };
            try t.expectEqual(@as(c_int, 0), rc);
            try compareOutput(host, oracle);
        }
        try host.pump(0);
        try t.expectEqual(@as(c_int, 0), spice_usbredir_host_pump(oracle, 0));
        try compareOutput(host, oracle);
        try host.detach();
        try t.expectEqual(@as(c_int, 0), spice_usbredir_host_detach(oracle));
        try compareOutput(host, oracle);
    }
}
test "bounds reject before side effects and preserve pending hello" {
    try t.expectError(error.InvalidArgument, Host.create(t.allocator, .{ .maximum_buffered_bytes = 0 }));
    try t.expectError(error.InvalidArgument, Host.create(t.allocator, .{ .maximum_buffered_bytes = 65 * 1024 * 1024 }));
    try t.expectError(error.InvalidArgument, Host.create(t.allocator, .{ .maximum_buffered_bytes = 8, .maximum_packet_bytes = 9 }));
    try t.expectError(error.USBBufferLimit, Host.create(t.allocator, .{ .maximum_buffered_bytes = 1, .maximum_packet_bytes = 1 }));
    const host = try Host.create(t.allocator, .{ .maximum_buffered_bytes = 4096, .maximum_packet_bytes = 8 });
    defer host.destroy();
    const size = host.outputSize();
    try t.expectError(error.InvalidArgument, host.receive(&.{}));
    try t.expectError(error.InvalidArgument, host.pump(101));
    var huge: [4097]u8 = undefined;
    @memset(&huge, 0);
    try t.expectError(error.USBBufferLimit, host.receive(&huge));
    try t.expectEqual(size, host.outputSize());
    // USB device addresses are 7-bit: this cannot select physical hardware.
    try t.expectError(error.USBDeviceNotFound, host.attach(255, 255));
}
fn allocationCase(a: std.mem.Allocator) !void {
    const host = try Host.create(a, .{ .maximum_buffered_bytes = 4096, .maximum_packet_bytes = 8 });
    defer host.destroy();
    while (host.outputSize() != 0) host.consumeOutput(host.peekOutput().len);
    try host.receive(&.{0});
    try host.receive(&.{0});
}
test "all Zig allocation failures clean native context and callback buffers" {
    try t.checkAllAllocationFailures(t.allocator, allocationCase, .{});
}
