//! Explicit host pasteboard access. AppKit stays on main; this synchronous
//! facade may run on a worker and cancellation wakes queued main-thread work.
const std = @import("std");
const sync = @import("sync.zig");
const cancel = @import("cancel.zig");
const Info = extern struct { change_count: i64, size: usize, present: u32, oversized: u32 };
const Complete = *const fn (*anyopaque, c_int, ?*anyopaque) callconv(.c) void;
extern "c" fn spice_zig_pb_create(?[*]const u8, usize, c_int) ?*anyopaque;
extern "c" fn spice_zig_pb_retain(*anyopaque) void;
extern "c" fn spice_zig_pb_destroy(?*anyopaque) void;
extern "c" fn spice_zig_pb_pending(*anyopaque) c_int;
extern "c" fn spice_zig_pb_begin(*anyopaque, c_int, ?[*]const u8, usize, usize, Complete, *anyopaque, *c_int) ?*anyopaque;
extern "c" fn spice_zig_pb_cancel(*anyopaque) void;
extern "c" fn spice_zig_pb_operation_destroy(*anyopaque) void;
extern "c" fn spice_zig_pb_result_info(*anyopaque, *Info) c_int;
extern "c" fn spice_zig_pb_result_bytes(*anyopaque) ?[*]const u8;
extern "c" fn spice_zig_pb_result_destroy(*anyopaque) void;
fn failure(status: c_int) anyerror {
    return switch (status) {
        -2 => error.Cancelled,
        -3 => error.PasteboardWriteFailed,
        -4 => error.InvalidUTF8,
        -5 => error.PasteboardBusy,
        else => error.PasteboardUnavailable,
    };
}
pub const Snapshot = struct {
    native: *anyopaque,
    change_count: i64,
    present: bool,
    oversized: bool,
    size: usize,
    pub fn deinit(self: Snapshot) void {
        spice_zig_pb_result_destroy(self.native);
    }
    pub fn bytes(self: Snapshot) !?[]const u8 {
        if (!self.present) return null;
        if (self.oversized) return error.OversizedLocalText;
        const data = spice_zig_pb_result_bytes(self.native) orelse {
            if (self.size == 0) return &.{};
            return error.InvalidNativeResult;
        };
        return data[0..self.size];
    }
};
pub const Context = struct {
    native: *anyopaque,
    /// null explicitly selects the general pasteboard. Tests use unique names.
    pub fn init(name: ?[]const u8) !Context {
        if (name) |value| {
            if (value.len == 0 or value.len > 4096 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidPasteboardName;
        }
        return .{ .native = spice_zig_pb_create(if (name) |v| v.ptr else null, if (name) |v| v.len else 0, @intFromBool(name == null)) orelse return error.PasteboardUnavailable };
    }
    pub fn retain(self: Context) Context {
        spice_zig_pb_retain(self.native);
        return self;
    }
    pub fn pending(self: Context) bool {
        return spice_zig_pb_pending(self.native) != 0;
    }
    pub fn deinit(self: Context) void {
        spice_zig_pb_destroy(self.native);
    }
    pub fn snapshot(self: Context, maximum: usize, token: *cancel.Token) !Snapshot {
        return self.perform(null, maximum, token);
    }
    pub fn write(self: Context, text: []const u8, maximum: usize, token: *cancel.Token) !Snapshot {
        // Explicit host writes may exceed the wire limit; captured bytes remain bounded by maximum.
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUTF8;
        return self.perform(text, maximum, token);
    }
    const Wait = struct {
        mutex: sync.Mutex = .{},
        changed: sync.Condition = .{},
        native: ?*anyopaque = null,
        cancelled: bool = false,
        done: bool = false,
        status: c_int = 0,
        result: ?*anyopaque = null,
        fn complete(p: *anyopaque, status: c_int, result: ?*anyopaque) callconv(.c) void {
            const self: *Wait = @ptrCast(@alignCast(p));
            self.mutex.lock();
            self.status = status;
            self.result = result;
            self.done = true;
            self.changed.broadcast();
            self.mutex.unlock();
        }
        fn wake(p: *anyopaque) void {
            const self: *Wait = @ptrCast(@alignCast(p));
            self.mutex.lock();
            self.cancelled = true;
            const native = self.native;
            self.mutex.unlock();
            if (native) |value| spice_zig_pb_cancel(value);
        }
    };
    fn perform(self: Context, text: ?[]const u8, maximum: usize, token: *cancel.Token) !Snapshot {
        if (maximum > 16 * 1024 * 1024) return error.InvalidLimits;
        var wait: Wait = .{};
        defer {
            wait.changed.deinit();
            wait.mutex.deinit();
        }
        var registration: cancel.Registration = .{ .context = &wait, .wake = Wait.wake };
        token.register(&registration);
        var registered = true;
        defer if (registered) token.unregister(&registration);
        try token.check();
        var status: c_int = 0;
        const operation = spice_zig_pb_begin(self.native, @intFromBool(text != null), if (text) |v| v.ptr else null, if (text) |v| v.len else 0, maximum, Wait.complete, &wait, &status) orelse return failure(status);
        // Unregister cancellation BEFORE releasing this caller-owned native handle.
        defer spice_zig_pb_operation_destroy(operation);
        wait.mutex.lock();
        wait.native = operation;
        const was_cancelled = wait.cancelled;
        wait.mutex.unlock();
        if (was_cancelled) spice_zig_pb_cancel(operation);
        wait.mutex.lock();
        while (!wait.done) wait.changed.wait(&wait.mutex);
        wait.mutex.unlock();
        token.unregister(&registration);
        registered = false;
        const result = wait.result;
        errdefer if (result) |value| spice_zig_pb_result_destroy(value);
        try token.check();
        if (wait.status != 0) return failure(wait.status);
        const value = result orelse return error.InvalidNativeResult;
        var info: Info = undefined;
        if (spice_zig_pb_result_info(value, &info) != 0) return error.InvalidNativeResult;
        return .{ .native = value, .change_count = info.change_count, .present = info.present != 0, .oversized = info.oversized != 0, .size = info.size };
    }
};
