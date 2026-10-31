//! Immutable, shared BGRA backing. Only the constructing decoder may mutate
//! pixels before publication. GPU/cache users retain until their work finishes.
const std = @import("std");
pub const Alpha = enum { opaque_pixels, straight, premultiplied };
pub const Image = struct {
    const Storage = struct { allocator: std.mem.Allocator, refs: std.atomic.Value(usize) = .init(1), pixels: []u8 };
    storage: *Storage,
    width: usize,
    height: usize,
    stride: usize,
    top_down: bool,
    alpha: Alpha,
    pub fn create(a: std.mem.Allocator, width: usize, height: usize, top_down: bool, alpha: Alpha) !Image {
        const stride = try std.math.mul(usize, width, 4);
        const size = try std.math.mul(usize, stride, height);
        if (width == 0 or height == 0) return error.InvalidDimensions;
        const storage = try a.create(Storage);
        errdefer a.destroy(storage);
        storage.* = .{ .allocator = a, .pixels = try a.alloc(u8, size) };
        return .{ .storage = storage, .width = width, .height = height, .stride = stride, .top_down = top_down, .alpha = alpha };
    }
    /// Takes the allocation only on success. Caller retains it on failure.
    pub fn adopt(a: std.mem.Allocator, width: usize, height: usize, top_down: bool, alpha: Alpha, pixels_data: []u8) !Image {
        const stride = try std.math.mul(usize, width, 4);
        if (width == 0 or height == 0 or pixels_data.len != try std.math.mul(usize, stride, height)) return error.InvalidDimensions;
        const storage = try a.create(Storage);
        storage.* = .{ .allocator = a, .pixels = pixels_data };
        return .{ .storage = storage, .width = width, .height = height, .stride = stride, .top_down = top_down, .alpha = alpha };
    }
    pub fn pixels(self: Image) []const u8 {
        return self.storage.pixels;
    }
    pub fn isUnique(self: Image) bool {
        return self.storage.refs.load(.acquire) == 1;
    }
    pub fn unpublishedPixels(self: Image) []u8 {
        std.debug.assert(self.storage.refs.load(.acquire) == 1);
        return self.storage.pixels;
    }
    pub fn retain(self: Image) Image {
        const old = self.storage.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old > 0 and old < std.math.maxInt(usize));
        return self;
    }
    pub fn release(self: Image) void {
        if (self.storage.refs.fetchSub(1, .acq_rel) == 1) {
            const a = self.storage.allocator;
            a.free(self.storage.pixels);
            a.destroy(self.storage);
        }
    }
};
