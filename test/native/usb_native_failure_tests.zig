const std = @import("std");
const t = std.testing;
const s = @import("spice");
extern fn spice_usb_fault_mode(c_int) void;
extern fn spice_usb_fault_live() c_int;
test "native failures free context list handle and pre-open callback storage exactly once" {
    for ([_]c_int{ 1, 2 }) |mode| {
        spice_usb_fault_mode(mode);
        if (mode == 1) try t.expectError(error.USBBackendFailure, s.usb_host.Host.create(t.allocator, .{})) else try t.expectError(error.USBBackendUnavailable, s.usb_host.Host.create(t.allocator, .{}));
        try t.expectEqual(@as(c_int, 0), spice_usb_fault_live());
    }
    for ([_]c_int{ 3, 4, 5, 6, 0 }) |mode| {
        spice_usb_fault_mode(0);
        const host = try s.usb_host.Host.create(t.allocator, .{});
        spice_usb_fault_mode(mode);
        switch (mode) {
            3, 5, 6 => try t.expectError(error.USBBackendFailure, host.attach(7, 9)),
            4 => try t.expectError(error.USBDeviceRejected, host.attach(7, 9)),
            else => try host.attach(7, 9),
        }
        if (mode == 6) try t.expectEqual(@as(c_int, 3), host.backend_code);
        host.destroy();
        try t.expectEqual(@as(c_int, 0), spice_usb_fault_live());
    }
}
test "callback output limit remains terminal and native read pump errors retain exact codes" {
    spice_usb_fault_mode(0);
    const host = try s.usb_host.Host.create(t.allocator, .{ .maximum_buffered_bytes = 8, .maximum_packet_bytes = 8 });
    defer host.destroy();
    spice_usb_fault_mode(9);
    try t.expectError(error.USBBackendFailure, host.receive("bad"));
    try t.expectEqual(@as(c_int, -2), host.backend_code);
    spice_usb_fault_mode(10);
    try t.expectError(error.USBBackendFailure, host.pump(0));
    try t.expectEqual(@as(c_int, -1), host.backend_code);
    spice_usb_fault_mode(8);
    try t.expectError(error.USBBackendFailure, host.pump(0));
    spice_usb_fault_mode(7);
    try t.expectError(error.USBBufferLimit, host.pump(0));
    try t.expectEqualStrings("HI", host.peekOutput());
    spice_usb_fault_mode(0);
    try t.expectError(error.USBBufferLimit, host.receive("no retry"));
    try t.expectError(error.USBBufferLimit, host.pump(0));
}
