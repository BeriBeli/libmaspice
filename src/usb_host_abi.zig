//! Serialized public boundary around the serial Zig/native host.
const std = @import("std");
const native = @import("usb_host.zig");
const sync = @import("sync.zig");
const a = std.heap.c_allocator;
pub const Options = extern struct { maximum_buffered_bytes: usize, maximum_packet_bytes: usize };
pub const Host = struct {
    value: *native.Host,
    mutex: sync.Mutex = .{},
    references: std.atomic.Value(usize) = .init(1),
    pub fn retain(self: *Host) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }
    pub fn release(self: *Host) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        self.value.destroy();
        self.mutex.deinit();
        a.destroy(self);
    }
};
pub fn status(err: anyerror) c_int {
    return switch (err) {
        error.InvalidArgument => -100,
        error.OutOfMemory => -101,
        error.USBBackendFailure, error.USBBackendUnavailable => -102,
        error.USBBufferLimit => -103,
        error.USBDeviceNotFound => -104,
        error.USBDeviceRejected => -105,
        error.USBQueueLimit => -106,
        error.USBNotReady => -107,
        error.Cancelled, error.Closed => -108,
        else => -1,
    };
}
pub export fn spice_zig_usb_host_options(output: ?*Options) void {
    if (output) |out| out.* = .{ .maximum_buffered_bytes = 16 * 1024 * 1024, .maximum_packet_bytes = 1024 * 1024 };
}
pub export fn spice_zig_usb_host_create(options: ?*const Options, output: ?*?*Host) c_int {
    const out = output orelse return -100;
    out.* = null;
    const opts = options orelse return -100;
    const value = native.Host.create(a, .{ .maximum_buffered_bytes = opts.maximum_buffered_bytes, .maximum_packet_bytes = opts.maximum_packet_bytes }) catch |err| return status(err);
    const self = a.create(Host) catch {
        value.destroy();
        return -101;
    };
    self.* = .{ .value = value };
    out.* = self;
    return 0;
}
pub export fn spice_zig_usb_host_destroy(handle: ?*Host) void {
    if (handle) |self| {
        self.release();
    }
}
pub export fn spice_zig_usb_host_receive(handle: ?*Host, data: ?[*]const u8, size: usize, native_code: ?*c_int) c_int {
    if (native_code) |out| out.* = 0;
    const self = handle orelse return -100;
    const source = data orelse return -100;
    self.mutex.lock();
    defer self.mutex.unlock();
    if (size == 0 or size > self.value.options.maximum_buffered_bytes) return if (size == 0) -100 else -103;
    self.value.receive(source[0..size]) catch |err| {
        if (native_code) |out| out.* = if (err == error.USBBackendFailure) self.value.backend_code else 0;
        return status(err);
    };
    return 0;
}
pub export fn spice_zig_usb_host_device(handle: ?*Host, attach: u8, bus: u8, address: u8, native_code: ?*c_int) c_int {
    if (native_code) |out| out.* = 0;
    const self = handle orelse return -100;
    if (attach > 1) return -100;
    self.mutex.lock();
    defer self.mutex.unlock();
    const result = if (attach == 1) self.value.attach(bus, address) else self.value.detach();
    if (result) |_| {} else |err| {
        if (native_code) |out| out.* = if (err == error.USBBackendFailure) self.value.backend_code else 0;
        return status(err);
    }
    return 0;
}
pub export fn spice_zig_usb_host_pump(handle: ?*Host, milliseconds: u32, native_code: ?*c_int) c_int {
    if (native_code) |out| out.* = 0;
    const self = handle orelse return -100;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.value.pump(milliseconds) catch |err| {
        if (native_code) |out| out.* = if (err == error.USBBackendFailure) self.value.backend_code else 0;
        return status(err);
    };
    return 0;
}
pub export fn spice_zig_usb_host_take(handle: ?*Host, output: ?[*]u8, capacity: usize, written: ?*usize) c_int {
    const count = written orelse return -100;
    count.* = 0;
    const self = handle orelse return -100;
    const target = output orelse return -100;
    if (capacity == 0) return -100;
    self.mutex.lock();
    defer self.mutex.unlock();
    const packet = self.value.peekOutput();
    const n = @min(capacity, packet.len);
    @memcpy(target[0..n], packet[0..n]);
    self.value.consumeOutput(n);
    count.* = n;
    return 0;
}

// Atomic standalone operation and drain. The owned output keeps an external
// runner from consuming or changing packets between a host call and its return.
pub const Packets = struct { data: []u8, packet_size: usize };
pub export fn spice_zig_usb_host_exchange(handle: ?*Host, kind: u8, data: ?[*]const u8, size: usize, bus: u8, address: u8, milliseconds: u32, output: ?*?*Packets, native_code: ?*c_int) c_int {
    if (native_code) |out| out.* = 0;
    const out = output orelse return -100;
    out.* = null;
    const self = handle orelse return -100;
    if (kind > 4 or (kind == 1 and (size == 0 or data == null))) return -100;
    self.mutex.lock();
    defer self.mutex.unlock();
    if (kind == 1 and size > self.value.options.maximum_buffered_bytes) return -103;
    const result = switch (kind) {
        0 => {},
        1 => self.value.receive(data.?[0..size]),
        2 => self.value.attach(bus, address),
        3 => self.value.detach(),
        4 => self.value.pump(milliseconds),
        else => unreachable,
    };
    if (result) |_| {} else |err| {
        if (native_code) |code| code.* = if (err == error.USBBackendFailure) self.value.backend_code else 0;
        return status(err);
    }
    const packets = a.create(Packets) catch return -101;
    const bytes = a.dupe(u8, self.value.output[self.value.output_offset..]) catch {
        a.destroy(packets);
        return -101;
    };
    packets.* = .{ .data = bytes, .packet_size = self.value.options.maximum_packet_bytes };
    self.value.consumeOutput(bytes.len);
    out.* = packets;
    return 0;
}
pub export fn spice_zig_usb_packets_bytes(handle: ?*const Packets, size: ?*usize, packet_size: ?*usize) ?[*]const u8 {
    if (size) |v| v.* = 0;
    if (packet_size) |v| v.* = 0;
    const self = handle orelse return null;
    if (size) |v| v.* = self.data.len;
    if (packet_size) |v| v.* = self.packet_size;
    return self.data.ptr;
}
pub export fn spice_zig_usb_packets_destroy(handle: ?*Packets) void {
    if (handle) |self| {
        a.free(self.data);
        a.destroy(self);
    }
}
