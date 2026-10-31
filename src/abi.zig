//! C ownership boundary only; all wire parsing lives in bytes/framer.
const std = @import("std");
const f = @import("framer.zig");
const a = std.heap.c_allocator;
comptime {
    _ = @import("ticket.zig");
}
const Handle = struct { framer: f.Framer };
const BatchHandle = struct { batch: f.Batch };
const lz = @import("lz.zig");
const ImageHandle = struct { image: lz.Image };

fn status(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => -2,
        error.Truncated => -3,
        error.InvalidOffset => -4,
        error.IntegerOverflow => -5,
        error.MessageTooLarge => -6,
        error.TooManySegments => -7,
        error.InvalidSize => -8,
        else => -1,
    };
}

pub export fn spice_zig_wire_create(mode: u8, message_limit: usize, buffered_limit: usize, segment_limit: usize) ?*Handle {
    if (mode > 1) return null;
    const handle = a.create(Handle) catch return null;
    handle.* = .{ .framer = .{ .allocator = a, .mode = if (mode == 0) .full else .mini, .limits = .{
        .message = message_limit,
        .buffered = buffered_limit,
        .segments = segment_limit,
    } } };
    return handle;
}
pub export fn spice_zig_wire_destroy(handle: ?*Handle) void {
    if (handle) |h| {
        h.framer.deinit();
        a.destroy(h);
    }
}
pub export fn spice_zig_wire_reset(handle: ?*Handle) void {
    if (handle) |h| h.framer.reset();
}
pub export fn spice_zig_wire_append(handle: ?*Handle, data: ?[*]const u8, size: usize) c_int {
    const h = handle orelse return -1;
    if (size == 0) return 0;
    const ptr = data orelse return -1;
    h.framer.append(ptr[0..size]) catch |err| return status(err);
    return 0;
}
/// 1 = owned batch, 0 = incomplete, negative = error. Allocate the ABI handle
/// before consuming the frame so allocation failure never loses input.
pub export fn spice_zig_wire_next(handle: ?*Handle, maximum: usize, output: ?*?*BatchHandle) c_int {
    const out = output orelse return -1;
    out.* = null;
    const h = handle orelse return -1;
    const result = a.create(BatchHandle) catch return -2;
    const batch = h.framer.nextBatch(maximum) catch |err| {
        a.destroy(result);
        return status(err);
    };
    if (batch) |value| {
        result.* = .{ .batch = value };
        out.* = result;
        return 1;
    }
    a.destroy(result);
    return 0;
}
pub export fn spice_zig_wire_buffered(handle: ?*const Handle) usize {
    return if (handle) |h| h.framer.buffered else 0;
}
pub export fn spice_zig_batch_destroy(handle: ?*BatchHandle) void {
    if (handle) |h| {
        h.batch.deinit();
        a.destroy(h);
    }
}
pub export fn spice_zig_batch_count(handle: ?*const BatchHandle) usize {
    return if (handle) |h| h.batch.logical.len else 0;
}
pub export fn spice_zig_batch_serial(handle: ?*const BatchHandle, output: ?*u64) c_int {
    const h = handle orelse return -1;
    const out = output orelse return -1;
    out.* = h.batch.message.serial orelse return 0;
    return 1;
}
pub export fn spice_zig_batch_message(handle: ?*const BatchHandle, index: usize, kind: ?*u16, data: ?*?[*]const u8, size: ?*usize) c_int {
    const h = handle orelse return -1;
    const k = kind orelse return -1;
    const d = data orelse return -1;
    const s = size orelse return -1;
    if (index >= h.batch.logical.len) return -1;
    const body = h.batch.body(index);
    k.* = h.batch.logical[index].kind;
    d.* = body.ptr;
    s.* = body.len;
    return 0;
}

pub export fn spice_zig_lz_decode(data: ?[*]const u8, size: usize, width: usize, height: usize, palette: ?[*]const u32, palette_count: usize, output: ?*?*ImageHandle) c_int {
    const out = output orelse return -1;
    out.* = null;
    if (data == null or (palette == null and palette_count != 0)) return -1;
    const result = a.create(ImageHandle) catch return -2;
    result.image = lz.decode(a, data.?[0..size], width, height, if (palette) |entries| entries[0..palette_count] else null, .{}) catch |err| {
        a.destroy(result);
        return switch (err) {
            error.OutOfMemory => -2,
            error.EncodedImageTooLarge, error.DecodedImageTooLarge => -6,
            error.InvalidDimensions => -21,
            error.DimensionMismatch => -22,
            error.UnsupportedFormat => -23,
            else => -20,
        };
    };
    out.* = result;
    return 0;
}
pub export fn spice_zig_image_destroy(handle: ?*ImageHandle) void {
    if (handle) |h| {
        h.image.deinit();
        a.destroy(h);
    }
}
pub export fn spice_zig_image_data(handle: ?*const ImageHandle, size: ?*usize) ?[*]const u8 {
    const out = size orelse return null;
    out.* = 0;
    const h = handle orelse return null;
    out.* = h.image.pixels.len;
    return h.image.pixels.ptr;
}
pub export fn spice_zig_image_flags(handle: ?*const ImageHandle) c_int {
    const h = handle orelse return -1;
    return @as(c_int, @intFromBool(h.image.top_down)) | (@as(c_int, @intFromBool(h.image.has_alpha)) << 1);
}
comptime {
    _ = @import("network_abi.zig");
}
comptime {
    _ = @import("session_abi.zig");
}
comptime {
    _ = @import("main_abi.zig");
}
