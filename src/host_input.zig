//! Main-thread desktop input policy. AppKit supplies scalar event values and
//! performs cursor system calls; held keys, mappings and geometry live here.
//! Batches own their values, so delivering input cannot reenter partial state.
const std = @import("std");
const inputs = @import("inputs.zig");
pub const Point = extern struct { x: f64 = 0, y: f64 = 0 };
pub const Rect = extern struct { x: f64 = 0, y: f64 = 0, width: f64 = 0, height: f64 = 0 };
pub const shift: u64 = 1 << 17;
pub const control: u64 = 1 << 18;
pub const option: u64 = 1 << 19;
pub const command: u64 = 1 << 20;
pub const numeric_pad: u64 = 1 << 21;
const Group = struct { flag: u64, left: u16, right: u16, left_mask: u64, right_mask: u64 };
const groups = [_]Group{
    .{ .flag = shift, .left = 0x2a, .right = 0x36, .left_mask = 2, .right_mask = 4 },
    .{ .flag = control, .left = 0x1d, .right = 0x11d, .left_mask = 1, .right_mask = 0x2000 },
    .{ .flag = option, .left = 0x38, .right = 0x138, .left_mask = 0x20, .right_mask = 0x40 },
    .{ .flag = command, .left = 0x15b, .right = 0x15c, .left_mask = 8, .right_mask = 0x10 },
};
const key_count = 0x15d;
pub const Batch = struct {
    storage: [key_count]inputs.Input = undefined,
    length: usize = 0,
    pub fn events(self: *const Batch) []const inputs.Input {
        return self.storage[0..self.length];
    }
    fn append(self: *Batch, event: inputs.Input) void {
        self.storage[self.length] = event;
        self.length += 1;
    }
};
pub const Keyboard = struct {
    held: [key_count]bool = @splat(false),
    fn modifiers(self: *Keyboard, flags: u64, result: *Batch) void {
        var managed: [key_count]bool = @splat(false);
        var desired: [key_count]bool = @splat(false);
        for (groups) |g| {
            managed[g.left] = true;
            managed[g.right] = true;
            if (flags & g.flag == 0) continue;
            if (flags & (g.left_mask | g.right_mask) != 0) {
                desired[g.left] = flags & g.left_mask != 0;
                desired[g.right] = flags & g.right_mask != 0;
            } else if (self.held[g.left] or self.held[g.right]) {
                desired[g.left] = self.held[g.left];
                desired[g.right] = self.held[g.right];
            } else desired[g.left] = true;
        }
        for (managed, 0..) |m, code| if (m and self.held[code] and !desired[code]) {
            self.held[code] = false;
            result.append(.{ .key_up = @intCast(code) });
        };
        for (managed, 0..) |m, code| if (m and !self.held[code] and desired[code]) {
            self.held[code] = true;
            result.append(.{ .key_down = @intCast(code) });
        };
    }
    /// null means the native responder should handle this unmapped key.
    pub fn key(self: *Keyboard, down: bool, virtual_key: u16, flags: u64, decimal_text: bool) ?Batch {
        const code = scanCode(virtual_key, flags, decimal_text) orelse return null;
        var result: Batch = .{};
        if (down) self.modifiers(flags, &result);
        self.held[code] = down;
        result.append(if (down) .{ .key_down = code } else .{ .key_up = code });
        return result;
    }
    pub fn flagsChanged(self: *Keyboard, virtual_key: u16, flags: u64) Batch {
        var result: Batch = .{};
        self.modifiers(flags, &result);
        if (virtual_key == 57) {
            self.held[0x3a] = !self.held[0x3a];
            result.append(if (self.held[0x3a]) .{ .key_down = 0x3a } else .{ .key_up = 0x3a });
        }
        return result;
    }
    pub fn releaseAll(self: *Keyboard) Batch {
        var result: Batch = .{};
        for (&self.held, 0..) |*held, code| if (held.*) {
            held.* = false;
            result.append(.{ .key_up = @intCast(code) });
        };
        return result;
    }
};
pub fn contentRect(bounds: Rect, width: u32, height: u32) Rect {
    if (width == 0 or height == 0 or !std.math.isFinite(bounds.x) or !std.math.isFinite(bounds.y) or
        !std.math.isFinite(bounds.width) or !std.math.isFinite(bounds.height) or bounds.width <= 0 or bounds.height <= 0) return .{};
    const scale = @min(bounds.width / @as(f64, @floatFromInt(width)), bounds.height / @as(f64, @floatFromInt(height)));
    const w = @as(f64, @floatFromInt(width)) * scale;
    const h = @as(f64, @floatFromInt(height)) * scale;
    const result: Rect = .{ .x = bounds.x + bounds.width / 2 - w / 2, .y = bounds.y + bounds.height / 2 - h / 2, .width = w, .height = h };
    return if (std.math.isFinite(result.x) and std.math.isFinite(result.y)) result else .{};
}
pub fn absolute(bounds: Rect, width: u32, height: u32, point: Point) ?inputs.Input {
    const rect = contentRect(bounds, width, height);
    if (rect.width <= 0 or rect.height <= 0 or !std.math.isFinite(point.x) or !std.math.isFinite(point.y) or
        point.x < rect.x or point.y < rect.y or point.x >= rect.x + rect.width or point.y >= rect.y + rect.height) return null;
    const x = @min(@as(f64, @floatFromInt(width - 1)), @max(0, ((point.x - rect.x) / rect.width) * @as(f64, @floatFromInt(width))));
    const y = @min(@as(f64, @floatFromInt(height - 1)), @max(0, ((point.y - rect.y) / rect.height) * @as(f64, @floatFromInt(height))));
    return .{ .position = .{ .x = @intFromFloat(x), .y = @intFromFloat(y), .display_id = 0 } };
}
pub fn delta(value: f64) i32 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(@min(@as(f64, std.math.maxInt(i32)), @max(@as(f64, std.math.minInt(i32)), @round(value))));
}
pub fn relative(captured: bool, dx: f64, dy: f64) ?inputs.Input {
    if (!captured) return null;
    const x = delta(dx);
    const y = delta(dy);
    return if (x == 0 and y == 0) null else .{ .motion = .{ .dx = x, .dy = y } };
}
pub fn otherButton(number: i64) inputs.Button {
    return switch (number) {
        2 => .middle,
        4 => .extra,
        else => .side,
    };
}
pub fn scroll(dy: f64) Batch {
    var result: Batch = .{};
    if (dy == 0 or !std.math.isFinite(dy)) return result;
    const button: inputs.Button = if (dy > 0) .scroll_up else .scroll_down;
    result.append(.{ .press = button });
    result.append(.{ .release = button });
    return result;
}
/// The owning view must release on focus/window loss and before destruction.
/// System callbacks are synchronous, main-thread-only and cannot reenter Capture.
pub const CaptureSystem = struct {
    context: *anyopaque,
    location: *const fn (*anyopaque) ?Point,
    disconnect: *const fn (*anyopaque) bool,
    warp: *const fn (*anyopaque, Point) void,
    reconnect: *const fn (*anyopaque) void,
    hide: *const fn (*anyopaque) void,
    unhide: *const fn (*anyopaque) void,
};
pub const Capture = struct {
    captured: bool = false,
    restore: ?Point = null,
    pub fn acquire(self: *Capture, system: CaptureSystem) bool {
        if (self.captured) return true;
        const location = system.location(system.context);
        if (!system.disconnect(system.context)) return false;
        self.restore = if (location) |p| (if (std.math.isFinite(p.x) and std.math.isFinite(p.y)) p else null) else null;
        system.hide(system.context);
        self.captured = true;
        return true;
    }
    pub fn release(self: *Capture, system: CaptureSystem) void {
        if (!self.captured) return;
        if (self.restore) |p| system.warp(system.context, p);
        system.reconnect(system.context);
        system.unhide(system.context);
        self.restore = null;
        self.captured = false;
    }
};
pub fn scanCode(virtual_key: u16, flags: u64, decimal_text: bool) ?u16 {
    if (virtual_key == 65 and decimal_text and flags & (numeric_pad | shift | control | option | command) == 0) return 0x34;
    return switch (virtual_key) {
        0 => 0x1e,
        1 => 0x1f,
        2 => 0x20,
        3 => 0x21,
        4 => 0x23,
        5 => 0x22,
        6 => 0x2c,
        7 => 0x2d,
        8 => 0x2e,
        9 => 0x2f,
        11 => 0x30,
        12 => 0x10,
        13 => 0x11,
        14 => 0x12,
        15 => 0x13,
        16 => 0x15,
        17 => 0x14,
        18 => 0x02,
        19 => 0x03,
        20 => 0x04,
        21 => 0x05,
        22 => 0x07,
        23 => 0x06,
        24 => 0x0d,
        25 => 0x0a,
        26 => 0x08,
        27 => 0x0c,
        28 => 0x09,
        29 => 0x0b,
        30 => 0x1b,
        31 => 0x18,
        32 => 0x16,
        33 => 0x1a,
        34 => 0x17,
        35 => 0x19,
        36 => 0x1c,
        37 => 0x26,
        38 => 0x24,
        39 => 0x28,
        40 => 0x25,
        41 => 0x27,
        42 => 0x2b,
        43 => 0x33,
        44 => 0x35,
        45 => 0x31,
        46 => 0x32,
        47 => 0x34,
        48 => 0x0f,
        49 => 0x39,
        50 => 0x29,
        51 => 0x0e,
        53 => 0x01,
        54 => 0x15c,
        55 => 0x15b,
        56 => 0x2a,
        57 => 0x3a,
        58 => 0x38,
        59 => 0x1d,
        60 => 0x36,
        61 => 0x138,
        62 => 0x11d,
        65 => 0x53,
        67 => 0x37,
        69 => 0x4e,
        71 => 0x45,
        75 => 0x135,
        76 => 0x11c,
        78 => 0x4a,
        81 => 0x59,
        82 => 0x52,
        83 => 0x4f,
        84 => 0x50,
        85 => 0x51,
        86 => 0x4b,
        87 => 0x4c,
        88 => 0x4d,
        89 => 0x47,
        91 => 0x48,
        92 => 0x49,
        96 => 0x3f,
        97 => 0x40,
        98 => 0x41,
        99 => 0x3d,
        100 => 0x42,
        101 => 0x43,
        103 => 0x57,
        105 => 0x64,
        106 => 0x67,
        107 => 0x65,
        109 => 0x44,
        111 => 0x58,
        113 => 0x66,
        114 => 0x152,
        115 => 0x147,
        116 => 0x149,
        117 => 0x153,
        118 => 0x3e,
        119 => 0x14f,
        120 => 0x3c,
        121 => 0x151,
        122 => 0x3b,
        123 => 0x14b,
        124 => 0x14d,
        125 => 0x150,
        126 => 0x148,
        else => null,
    };
}
