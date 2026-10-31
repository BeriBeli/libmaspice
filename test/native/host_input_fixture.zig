const std = @import("std");
const h = @import("spice").host_input;
export fn keyboard_create() ?*h.Keyboard {
    const p = std.heap.c_allocator.create(h.Keyboard) catch return null;
    p.* = .{};
    return p;
}
export fn keyboard_destroy(p: *h.Keyboard) void {
    std.heap.c_allocator.destroy(p);
}
export fn keyboard_step(p: *h.Keyboard, op: u32, key: u16, flags: u64, decimal: u8, out: [*]u32) i32 {
    const batch = switch (op) {
        0, 1 => p.key(op == 0, key, flags, decimal != 0) orelse return -1,
        2 => p.flagsChanged(key, flags),
        3 => p.releaseAll(),
        else => return -2,
    };
    for (batch.events(), 0..) |event, i| out[i] = switch (event) {
        .key_down => |v| 0x10000 | v,
        .key_up => |v| 0x20000 | v,
        else => unreachable,
    };
    return @intCast(batch.length);
}
export fn host_geometry(bounds: *const h.Rect, width: u32, height: u32, point: *const h.Point, out: [*]f64) void {
    const rect = h.contentRect(bounds.*, width, height);
    out[0] = rect.x;
    out[1] = rect.y;
    out[2] = rect.width;
    out[3] = rect.height;
    out[4] = -1;
    out[5] = -1;
    if (h.absolute(bounds.*, width, height, point.*)) |v| {
        out[4] = @floatFromInt(v.position.x);
        out[5] = @floatFromInt(v.position.y);
    }
}
