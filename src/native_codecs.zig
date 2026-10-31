//! Static JPEG and production Zig QUIC adapters. Pixel quality matches the
//! existing accurate IDCT/fancy-upsample Neon path, including CMYK conversion.
const std = @import("std");
const cancel = @import("cancel.zig");
const sync = @import("sync.zig");
const Image = @import("image.zig").Image;
extern "c" fn spice_zig_jpeg_create() ?*anyopaque;
extern "c" fn spice_zig_jpeg_destroy(*anyopaque) void;
extern "c" fn spice_zig_jpeg_header(*anyopaque, [*]const u8, usize, *c_int, *c_int, *c_int) c_int;
extern "c" fn spice_zig_jpeg_pixels(*anyopaque, [*]const u8, usize, [*]u8, c_int, c_int, c_int, c_int) c_int;
extern "c" fn spice_zig_quic_image([*]const u8, usize, c_int, c_int, [*]u8, usize, *c_int) c_int;
pub const Limits = struct { dimension: usize = 16384, encoded: usize = 64 * 1024 * 1024, decoded: usize = 256 * 1024 * 1024 };
fn validate(data: []const u8, width: usize, height: usize, limits: Limits) !void {
    if (data.len == 0) return error.EmptyPayload;
    if (data.len > limits.encoded) return error.EncodedImageTooLarge;
    if (width == 0 or height == 0 or width > limits.dimension or height > limits.dimension or width > std.math.maxInt(c_int) / 4 or height > std.math.maxInt(c_int)) return error.InvalidDimensions;
    if (try std.math.mul(usize, try std.math.mul(usize, width, height), 4) > limits.decoded) return error.DecodedImageTooLarge;
}
pub const JPEG = struct {
    handle: *anyopaque,
    mutex: sync.Mutex = .{},
    pub fn init() !JPEG {
        return .{ .handle = spice_zig_jpeg_create() orelse return error.NativeAllocationFailed };
    }
    pub fn deinit(self: *JPEG) void {
        spice_zig_jpeg_destroy(self.handle);
        self.mutex.deinit();
    }
    /// A persistent handle can also decode directly into an unpublished native
    /// IOSurface mapping. Row padding is left untouched.
    pub fn into(self: *JPEG, data: []const u8, width: usize, height: usize, output: []u8, stride: usize, limits: Limits, token: *cancel.Token) !void {
        try token.check();
        try validate(data, width, height, limits);
        if (stride < width * 4 or stride > std.math.maxInt(c_int) or output.len < try std.math.mul(usize, stride, height)) return error.InvalidDestination;
        self.mutex.lock();
        defer self.mutex.unlock();
        try token.check();
        var w: c_int = 0;
        var h: c_int = 0;
        var cmyk: c_int = 0;
        if (spice_zig_jpeg_header(self.handle, data.ptr, data.len, &w, &h, &cmyk) != 0) return error.InvalidJPEGHeader;
        if (w != width or h != height) return error.DimensionMismatch;
        if (spice_zig_jpeg_pixels(self.handle, data.ptr, data.len, output.ptr, w, @intCast(stride), h, cmyk) != 0) return error.JPEGDecodeFailed;
        if (cmyk != 0) {
            for (0..height) |y| {
                try token.check();
                for (0..width) |x| {
                    const offset = y * stride + x * 4;
                    const c: u16 = output[offset];
                    const m: u16 = output[offset + 1];
                    const yellow: u16 = output[offset + 2];
                    const black: u16 = output[offset + 3];
                    output[offset] = @intCast(((255 - yellow) * (255 - black) + 127) / 255);
                    output[offset + 1] = @intCast(((255 - m) * (255 - black) + 127) / 255);
                    output[offset + 2] = @intCast(((255 - c) * (255 - black) + 127) / 255);
                    output[offset + 3] = 255;
                }
            }
        }
        try token.check();
    }
    pub fn decode(self: *JPEG, a: std.mem.Allocator, data: []const u8, width: usize, height: usize, limits: Limits, token: *cancel.Token) !Image {
        try validate(data, width, height, limits);
        const image = try Image.create(a, width, height, true, .opaque_pixels);
        errdefer image.release();
        try self.into(data, width, height, image.unpublishedPixels(), image.stride, limits, token);
        return image;
    }
};
pub fn quic(a: std.mem.Allocator, data: []const u8, width: usize, height: usize, limits: Limits, token: *cancel.Token) !Image {
    try token.check();
    try validate(data, width, height, limits);
    if (data.len % 4 != 0) return error.InvalidContainer;
    var image = try Image.create(a, width, height, true, .opaque_pixels);
    errdefer image.release();
    var kind: c_int = 0;
    const output = image.unpublishedPixels();
    switch (spice_zig_quic_image(data.ptr, data.len, @intCast(width), @intCast(height), output.ptr, output.len, &kind)) {
        0 => {},
        2 => return error.DimensionMismatch,
        3 => return error.UnsupportedFormat,
        4 => return error.OutOfMemory,
        else => return error.InvalidQUIC,
    }
    try token.check();
    if (kind == 5) image.alpha = .straight;
    return image;
}
