//! Scan only the bounded two-row causal marker ROI in borrowed BGRA storage.
//! IOSurface callers map read-only storage for this call, without full readback.
const std = @import("std");
const record = @import("interaction_record.zig");
pub const Payload = struct { token: u64, revision: u64, checksum: u32 };
pub const Detection = union(enum) { none, exact: Payload, ambiguous: usize };
pub fn detect(pixels: []const u8, width: usize, height: usize, stride: usize, expected_token: []const u8, expected_checksum: u32) Detection {
    if (!record.lowerHex(expected_token, 16)) return .none;
    const token = std.fmt.parseInt(u64, expected_token, 16) catch return .none;
    if (width < 360 or height < 16 or width > std.math.maxInt(usize) / 4 or stride < width * 4) return .none;
    const max_x: usize = @min(32, width - 352);
    const max_y: usize = @min(32, height - 8);
    const row = std.math.mul(usize, max_y + 7, stride) catch return .none;
    const required = std.math.add(usize, row, (max_x + 352) * 4) catch return .none;
    if (required > pixels.len) return .none;
    var count: usize = 0;
    var matched: Payload = undefined;
    var y: usize = 8;
    while (y <= max_y) : (y += 4) {
        var x: usize = 8;
        while (x <= max_x) : (x += 4) {
            const payload = decode(pixels, stride, x, y) orelse continue;
            if (payload.token != token or payload.checksum != expected_checksum) continue;
            matched = payload;
            count += 1;
        }
    }
    return switch (count) {
        0 => .none,
        1 => .{ .exact = matched },
        else => .{ .ambiguous = count },
    };
}
fn decode(pixels: []const u8, stride: usize, x: usize, y: usize) ?Payload {
    var bits: u176 = 0;
    for (0..176) |i| {
        const offset = (y + (i / 88) * 4 + 2) * stride + (x + (i % 88) * 4 + 2) * 4;
        const b = pixels[offset];
        const g = pixels[offset + 1];
        const r = pixels[offset + 2];
        const bit: u1 = if (b <= 8 and g <= 8 and r <= 8) 1 else if (b >= 247 and g >= 247 and r >= 247) 0 else return null;
        bits = (bits << 1) | bit;
    }
    if (bits >> 160 != 0xa5c3) return null;
    return .{ .token = @truncate(bits >> 96), .revision = @truncate(bits >> 32), .checksum = @truncate(bits) };
}
