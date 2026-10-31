//! Retains the caller's existing backend. Serial native calls hold Host.mutex;
//! network writes use an independent bounded packet and never hold that mutex.
const std = @import("std");
const abi = @import("usb_host_abi.zig");
const native = @import("usb_host.zig");
pub const Backend = struct {
    allocator: std.mem.Allocator,
    host: *abi.Host,
    packet: []u8,
    count: usize = 0,
    activated: bool = false,
    backend_code: c_int = 0,
    pub fn create(a: std.mem.Allocator, options: native.Options) !*Backend {
        var host: ?*abi.Host = null;
        const result = abi.spice_zig_usb_host_create(&.{ .maximum_buffered_bytes = options.maximum_buffered_bytes, .maximum_packet_bytes = options.maximum_packet_bytes }, &host);
        if (result != 0) return if (result == -101) error.OutOfMemory else error.USBBackendUnavailable;
        defer host.?.release();
        return createExisting(a, host.?);
    }
    pub fn createExisting(a: std.mem.Allocator, host: *abi.Host) !*Backend {
        const self = try a.create(Backend);
        errdefer a.destroy(self);
        const packet = try a.alloc(u8, @min(host.value.options.maximum_packet_bytes, 1024 * 1024));
        host.retain();
        self.* = .{ .allocator = a, .host = host, .packet = packet };
        return self;
    }
    pub fn destroy(self: *Backend) void {
        self.host.mutex.lock();
        if (self.activated) self.host.value.detach() catch {};
        self.host.mutex.unlock();
        self.abandon();
    }
    // A runner that never started must not detach a caller's existing device.
    pub fn abandon(self: *Backend) void {
        self.host.release();
        self.allocator.free(self.packet);
        self.allocator.destroy(self);
    }
    fn completed(self: *Backend, result: anyerror!void) !void {
        self.backend_code = self.host.value.backend_code;
        try result;
    }
    pub fn receive(self: *Backend, data: []const u8) !void {
        self.activated = true;
        self.host.mutex.lock();
        defer self.host.mutex.unlock();
        try self.completed(self.host.value.receive(data));
    }
    pub fn attach(self: *Backend, bus: u8, address: u8) !void {
        self.activated = true;
        self.host.mutex.lock();
        defer self.host.mutex.unlock();
        try self.completed(self.host.value.attach(bus, address));
    }
    pub fn detach(self: *Backend) !void {
        self.activated = true;
        self.host.mutex.lock();
        defer self.host.mutex.unlock();
        try self.completed(self.host.value.detach());
    }
    pub fn pump(self: *Backend, milliseconds: u32) !void {
        self.activated = true;
        self.host.mutex.lock();
        defer self.host.mutex.unlock();
        try self.completed(self.host.value.pump(milliseconds));
    }
    pub fn outputSize(self: *Backend) usize {
        if (self.count != 0) return self.count;
        self.host.mutex.lock();
        defer self.host.mutex.unlock();
        const bytes = self.host.value.peekOutput();
        const count = @min(bytes.len, self.packet.len);
        @memcpy(self.packet[0..count], bytes[0..count]);
        self.host.value.consumeOutput(count);
        self.count = count;
        return count;
    }
    pub fn peekOutput(self: *Backend) []const u8 {
        return self.packet[0..self.count];
    }
    pub fn consumeOutput(self: *Backend, count: usize) void {
        std.debug.assert(count == self.count);
        self.count = 0;
    }
};
