//! Exact libusbredirhost backend. One serial owner calls every method, including
//! destroy; the joined runner supplies this ownership. Native calls may invoke
//! callbacks before open returns or while closing: Host stays at a stable address
//! until both usbredirhost and libusb have finished. No automatic device selection.
const std = @import("std");
const Context = opaque {};
const NativeHost = opaque {};
const Device = opaque {};
const Handle = opaque {};
const Rules = opaque {};
const IO = *const fn (?*anyopaque, ?[*]u8, c_int) callconv(.c) c_int;
extern fn libusb_init(*?*Context) c_int;
extern fn libusb_exit(*Context) void;
extern fn libusb_get_device_list(*Context, *?[*]*Device) isize;
extern fn libusb_free_device_list([*]*Device, c_int) void;
extern fn libusb_get_bus_number(*Device) u8;
extern fn libusb_get_device_address(*Device) u8;
extern fn libusb_open(*Device, *?*Handle) c_int;
extern fn libusb_handle_events_timeout_completed(*Context, *const std.c.timeval, ?*c_int) c_int;
extern fn usbredirhost_open(*Context, ?*Handle, *const fn (?*anyopaque, c_int, ?[*:0]const u8) callconv(.c) void, IO, IO, ?*anyopaque, [*:0]const u8, c_int, c_int) ?*NativeHost;
extern fn usbredirhost_close(*NativeHost) void;
extern fn usbredirhost_set_device(*NativeHost, ?*Handle) c_int;
extern fn usbredirhost_read_guest_data(*NativeHost) c_int;
extern fn usbredirhost_has_data_to_write(*NativeHost) c_int;
extern fn usbredirhost_write_guest_data(*NativeHost) c_int;
extern fn usbredirhost_get_guest_filter(*NativeHost, *?*const Rules, *c_int) void;
extern fn usbredirhost_check_device_filter(?*const Rules, c_int, *Device, c_int) c_int;
pub const Options = struct {
    maximum_buffered_bytes: usize = 16 * 1024 * 1024,
    maximum_packet_bytes: usize = 1024 * 1024,
    pub fn validate(self: Options) !void {
        if (self.maximum_buffered_bytes == 0 or self.maximum_buffered_bytes > 64 * 1024 * 1024 or self.maximum_packet_bytes == 0 or self.maximum_packet_bytes > self.maximum_buffered_bytes) return error.InvalidArgument;
    }
};
pub const Host = struct {
    allocator: std.mem.Allocator,
    options: Options,
    context: ?*Context = null,
    native: ?*NativeHost = null,
    input: []u8 = &.{},
    input_offset: usize = 0,
    output: []u8 = &.{},
    output_offset: usize = 0,
    callback_error: ?anyerror = null,
    backend_code: c_int = 0,
    pub fn create(a: std.mem.Allocator, options: Options) !*Host {
        try options.validate();
        const self = try a.create(Host);
        self.* = .{ .allocator = a, .options = options };
        errdefer self.destroy();
        try self.check(libusb_init(&self.context));
        self.native = usbredirhost_open(self.context.?, null, log, read, write, self, "spice-swift", 0, 0) orelse return self.callback_error orelse error.USBBackendUnavailable;
        try self.flush();
        return self;
    }
    pub fn destroy(self: *Host) void {
        if (self.native) |host| usbredirhost_close(host);
        if (self.context) |context| libusb_exit(context);
        self.allocator.free(self.input);
        self.allocator.free(self.output);
        self.allocator.destroy(self);
    }
    fn check(self: *Host, code: c_int) !void {
        if (code != 0) {
            self.backend_code = code;
            return error.USBBackendFailure;
        }
    }
    fn flush(self: *Host) !void {
        if (self.callback_error) |err| return err;
        while (usbredirhost_has_data_to_write(self.native.?) > 0) {
            const code = usbredirhost_write_guest_data(self.native.?);
            if (self.callback_error) |err| return err;
            try self.check(code);
        }
    }
    pub fn receive(self: *Host, bytes: []const u8) !void {
        if (bytes.len == 0) return error.InvalidArgument;
        if (self.callback_error) |err| return err;
        const remaining = self.input[self.input_offset..];
        if (bytes.len > self.options.maximum_buffered_bytes - remaining.len) return error.USBBufferLimit;
        const combined = try self.allocator.alloc(u8, remaining.len + bytes.len);
        @memcpy(combined[0..remaining.len], remaining);
        @memcpy(combined[remaining.len..], bytes);
        self.allocator.free(self.input);
        self.input = combined;
        self.input_offset = 0;
        try self.check(usbredirhost_read_guest_data(self.native.?));
        try self.flush();
    }
    /// Caller explicitly authorizes this exact device. Check the guest filter
    /// before libusb_open. set_device consumes the handle even on failure.
    pub fn attach(self: *Host, bus: u8, address: u8) !void {
        if (self.callback_error) |err| return err;
        var devices: ?[*]*Device = null;
        const count = libusb_get_device_list(self.context.?, &devices);
        if (count < 0) return self.check(@intCast(count));
        defer if (devices) |list| libusb_free_device_list(list, 1);
        if (devices) |list| for (list[0..@intCast(count)]) |device| {
            if (libusb_get_bus_number(device) != bus or libusb_get_device_address(device) != address) continue;
            var rules: ?*const Rules = null;
            var rule_count: c_int = 0;
            usbredirhost_get_guest_filter(self.native.?, &rules, &rule_count);
            if (rule_count > 0 and usbredirhost_check_device_filter(rules, rule_count, device, 0) != 0) return error.USBDeviceRejected;
            var handle: ?*Handle = null;
            try self.check(libusb_open(device, &handle));
            try self.check(usbredirhost_set_device(self.native.?, handle));
            return self.flush();
        };
        return error.USBDeviceNotFound;
    }
    pub fn detach(self: *Host) !void {
        try self.check(usbredirhost_set_device(self.native.?, null));
        try self.flush();
    }
    pub fn pump(self: *Host, milliseconds: u32) !void {
        if (milliseconds > 100) return error.InvalidArgument;
        if (self.callback_error) |err| return err;
        const timeout: std.c.timeval = .{ .sec = 0, .usec = @intCast(milliseconds * 1000) };
        try self.check(libusb_handle_events_timeout_completed(self.context.?, &timeout, null));
        try self.flush();
    }
    pub fn outputSize(self: *const Host) usize {
        return self.output.len - self.output_offset;
    }
    /// Borrows the next bounded packet until consumeOutput or another host call.
    pub fn peekOutput(self: *const Host) []const u8 {
        return self.output[self.output_offset..][0..@min(self.outputSize(), self.options.maximum_packet_bytes)];
    }
    pub fn consumeOutput(self: *Host, count: usize) void {
        std.debug.assert(count <= self.outputSize());
        self.output_offset += count;
        if (self.output_offset == self.output.len) {
            self.allocator.free(self.output);
            self.output = &.{};
            self.output_offset = 0;
        }
    }
    fn log(_: ?*anyopaque, _: c_int, _: ?[*:0]const u8) callconv(.c) void {}
    fn read(raw: ?*anyopaque, destination: ?[*]u8, count: c_int) callconv(.c) c_int {
        const self: *Host = @ptrCast(@alignCast(raw orelse return -1));
        const target = destination orelse return -1;
        if (count < 0) return -1;
        const remaining = self.input[self.input_offset..];
        const copied = @min(remaining.len, @as(usize, @intCast(count)));
        @memcpy(target[0..copied], remaining[0..copied]);
        self.input_offset += copied;
        if (self.input_offset == self.input.len) {
            self.allocator.free(self.input);
            self.input = &.{};
            self.input_offset = 0;
        }
        return @intCast(copied);
    }
    fn write(raw: ?*anyopaque, data: ?[*]u8, count: c_int) callconv(.c) c_int {
        const self: *Host = @ptrCast(@alignCast(raw orelse return -1));
        const source = data orelse return -1;
        if (count < 0) return -1;
        if (self.callback_error != null) return -1;
        const added: usize = @intCast(count);
        const remaining = self.output[self.output_offset..];
        if (added > self.options.maximum_buffered_bytes - remaining.len) {
            self.callback_error = error.USBBufferLimit;
            return -1;
        }
        // Exact allocation bounds retained storage, including consumed prefixes.
        // A failed callback leaves the previous output intact and is terminal.
        const expanded = if (self.output_offset == 0)
            self.allocator.realloc(self.output, remaining.len + added) catch |err| {
                self.callback_error = err;
                return -1;
            }
        else blk: {
            const allocation = self.allocator.alloc(u8, remaining.len + added) catch |err| {
                self.callback_error = err;
                return -1;
            };
            @memcpy(allocation[0..remaining.len], remaining);
            self.allocator.free(self.output);
            break :blk allocation;
        };
        @memcpy(expanded[remaining.len..], source[0..added]);
        self.output = expanded;
        self.output_offset = 0;
        return count;
    }
};
