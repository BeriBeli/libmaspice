//! Serialized decoder ownership. Parsing, parameter replacement, session policy,
//! limits and pixel conversion live here; native bridge only calls Apple APIs.
//! Cancellation discards output after synchronous hardware work finishes; callers
//! must join decode before deinit. No encoded reference frame is skipped here.
const std = @import("std");
const annex = @import("annexb.zig");
const sync = @import("sync.zig");
const cancel = @import("cancel.zig");
const Image = @import("image.zig").Image;
extern "c" fn spice_zig_video_format(c_int, [*]const [*]const u8, [*]const usize, usize, *?*anyopaque) i32;
extern "c" fn spice_zig_video_format_release(*anyopaque) void;
extern "c" fn spice_zig_video_format_size(*anyopaque, *i32, *i32) void;
extern "c" fn spice_zig_video_session(*anyopaque, *?*anyopaque) i32;
extern "c" fn spice_zig_video_realtime(*anyopaque) i32;
extern "c" fn spice_zig_video_hardware(*anyopaque, *c_int) i32;
extern "c" fn spice_zig_video_session_release(*anyopaque) void;
extern "c" fn spice_zig_video_decode(*anyopaque, *anyopaque, [*]const u8, usize, u32, *anyopaque, *const fn (*anyopaque) callconv(.c) void, *?*anyopaque) i32;
extern "c" fn spice_zig_video_frame_release(*anyopaque) void;
extern "c" fn spice_zig_video_frame_retain(*anyopaque) void;
extern "c" fn spice_zig_video_metadata(*anyopaque, *[5]u32) c_int;
extern "c" fn spice_zig_video_lock(*anyopaque) c_int;
extern "c" fn spice_zig_video_unlock(*anyopaque) c_int;
extern "c" fn spice_zig_video_plane(*anyopaque, usize, *?[*]const u8, *usize, *usize, *usize) c_int;
pub const Limits = struct { parser: annex.Limits = .{}, decoded: usize = 256 * 1024 * 1024, dimension: usize = 16384 };
pub const Stats = struct { sessions: usize = 0, hardware: usize = 0, software: usize = 0, query_failed: usize = 0, frames: usize = 0, dropped: usize = 0 };
const Sample = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    fn release(context: *anyopaque) callconv(.c) void {
        const self: *Sample = @ptrCast(@alignCast(context));
        const a = self.allocator;
        a.free(self.bytes);
        a.destroy(self);
    }
};
fn dimensions(width: usize, height: usize, limits: Limits) !void {
    if (width == 0 or height == 0 or width > limits.dimension or height > limits.dimension) return error.InvalidDimensions;
    if (try std.math.mul(usize, try std.math.mul(usize, width, height), 4) > limits.decoded) return error.DecodedImageTooLarge;
}
pub const Frame = struct {
    handle: *anyopaque,
    width: usize,
    height: usize,
    format: enum { unsupported, bgra, nv12 },
    matrix: enum { unknown, bt601, bt709 },
    range: enum { unknown, full, video },
    /// Consumes a +1 pixel buffer on success AND failure.
    pub fn take(handle: *anyopaque, width: usize, height: usize, limits: Limits) !Frame {
        errdefer spice_zig_video_frame_release(handle);
        try dimensions(width, height, limits);
        var m: [5]u32 = undefined;
        if (spice_zig_video_metadata(handle, &m) != 0) return error.InvalidPixelBuffer;
        if (m[0] != width or m[1] != height) return error.DimensionMismatch;
        return .{ .handle = handle, .width = width, .height = height, .format = switch (m[2]) {
            1 => .bgra,
            2 => .nv12,
            else => .unsupported,
        }, .matrix = switch (m[3]) {
            601 => .bt601,
            709 => .bt709,
            else => .unknown,
        }, .range = switch (m[4]) {
            1 => .full,
            2 => .video,
            else => .unknown,
        } };
    }
    pub fn clone(self: Frame) Frame {
        spice_zig_video_frame_retain(self.handle);
        return self;
    }
    pub fn deinit(self: Frame) void {
        spice_zig_video_frame_release(self.handle);
    }
    const Plane = struct { bytes: []const u8, stride: usize };
    fn plane(self: Frame, index: usize, width: usize, height: usize, row: usize) !Plane {
        var ptr: ?[*]const u8 = null;
        var w: usize = 0;
        var h: usize = 0;
        var stride: usize = 0;
        if (spice_zig_video_plane(self.handle, index, &ptr, &w, &h, &stride) != 0 or w < width or h < height or stride < row) return error.InvalidPixelBuffer;
        return .{ .bytes = ptr.?[0..try std.math.mul(usize, stride, height)], .stride = stride };
    }
    /// Preserves the existing Swift integer CPU conversion, including its BT601
    /// fallback for unknown attachments. Metadata stays unknown for GPU policy.
    pub fn copyBGRA(self: Frame, a: std.mem.Allocator, token: *cancel.Token) !Image {
        try token.check();
        if (self.format == .unsupported) return error.UnsupportedPixelFormat;
        if (spice_zig_video_lock(self.handle) != 0) return error.PixelBufferLockFailed;
        var locked = true;
        defer if (locked) {
            _ = spice_zig_video_unlock(self.handle);
        };
        const image = try Image.create(a, self.width, self.height, true, .opaque_pixels);
        errdefer image.release();
        const pixels = image.unpublishedPixels();
        const yplane = try self.plane(0, self.width, self.height, self.width * @as(usize, if (self.format == .bgra) 4 else 1));
        if (self.format == .bgra) {
            for (0..self.height) |y| {
                try token.check();
                @memcpy(pixels[y * image.stride ..][0 .. self.width * 4], yplane.bytes[y * yplane.stride ..][0 .. self.width * 4]);
            }
        } else {
            const chroma = try self.plane(1, (self.width + 1) / 2, (self.height + 1) / 2, ((self.width + 1) / 2) * 2);
            const bt709 = self.matrix == .bt709;
            for (0..self.height) |y| {
                try token.check();
                for (0..self.width) |x| {
                    const value: i32 = yplane.bytes[y * yplane.stride + x];
                    const offset = (y / 2) * chroma.stride + (x / 2) * 2;
                    const cb: i32 = @as(i32, chroma.bytes[offset]) - 128;
                    const cr: i32 = @as(i32, chroma.bytes[offset + 1]) - 128;
                    var r: i32 = undefined;
                    var g: i32 = undefined;
                    var b: i32 = undefined;
                    if (self.range == .full) {
                        r = value + @divTrunc(@as(i32, if (bt709) 403 else 359) * cr + 128, 256);
                        g = value - @divTrunc(@as(i32, if (bt709) 48 else 88) * cb + @as(i32, if (bt709) 120 else 183) * cr + 128, 256);
                        b = value + @divTrunc(@as(i32, if (bt709) 475 else 454) * cb + 128, 256);
                    } else {
                        const scaled = @max(0, value - 16) * 298;
                        r = @divTrunc(scaled + @as(i32, if (bt709) 459 else 409) * cr + 128, 256);
                        g = @divTrunc(scaled - @as(i32, if (bt709) 55 else 100) * cb - @as(i32, if (bt709) 136 else 208) * cr + 128, 256);
                        b = @divTrunc(scaled + @as(i32, if (bt709) 541 else 516) * cb + 128, 256);
                    }
                    const dest = y * image.stride + x * 4;
                    pixels[dest] = @intCast(std.math.clamp(b, 0, 255));
                    pixels[dest + 1] = @intCast(std.math.clamp(g, 0, 255));
                    pixels[dest + 2] = @intCast(std.math.clamp(r, 0, 255));
                    pixels[dest + 3] = 255;
                }
            }
        }
        locked = false;
        if (spice_zig_video_unlock(self.handle) != 0) return error.PixelBufferUnlockFailed;
        try token.check();
        return image;
    }
};
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    codec: annex.Codec,
    width: usize,
    height: usize,
    limits: Limits,
    mutex: sync.Mutex = .{},
    parameters: [3]?[]u8 = .{ null, null, null },
    dirty: bool = false,
    format: ?*anyopaque = null,
    session: ?*anyopaque = null,
    stats: Stats = .{},
    last_status: i32 = 0,
    pub fn init(a: std.mem.Allocator, codec: annex.Codec, width: usize, height: usize, limits: Limits) !Decoder {
        try dimensions(width, height, limits);
        return .{ .allocator = a, .codec = codec, .width = width, .height = height, .limits = limits };
    }
    pub fn deinit(self: *Decoder) void {
        if (self.session) |p| spice_zig_video_session_release(p);
        if (self.format) |p| spice_zig_video_format_release(p);
        for (self.parameters) |p| if (p) |bytes| self.allocator.free(bytes);
        self.mutex.deinit();
    }
    fn parameterIndex(self: *Decoder, kind: u8) usize {
        return if (self.codec == .h265) kind - 32 else switch (kind) {
            7 => 0,
            8 => 1,
            13 => 2,
            else => unreachable,
        };
    }
    fn update(self: *Decoder, unit: annex.Unit) !void {
        var staged: [3]?[]u8 = .{ null, null, null };
        defer for (staged) |p| if (p) |bytes| self.allocator.free(bytes);
        for (unit.nals) |nal| if (nal.parameter) {
            const index = self.parameterIndex(nal.kind);
            const old = staged[index] orelse self.parameters[index];
            if (old) |bytes| {
                if (std.mem.eql(u8, bytes, nal.bytes)) continue;
            }
            const copy = try self.allocator.dupe(u8, nal.bytes);
            if (staged[index]) |bytes| self.allocator.free(bytes);
            staged[index] = copy;
        };
        for (&staged, &self.parameters) |*next, *previous| if (next.*) |bytes| {
            if (previous.*) |old| self.allocator.free(old);
            previous.* = bytes;
            next.* = null;
            self.dirty = true;
        };
    }
    fn rebuild(self: *Decoder) !void {
        if (self.parameters[0] == null or self.parameters[1] == null or (self.codec == .h265 and self.parameters[2] == null)) return;
        var ptrs: [3][*]const u8 = undefined;
        var sizes: [3]usize = undefined;
        var count: usize = 0;
        for (self.parameters) |p| if (p) |bytes| {
            ptrs[count] = bytes.ptr;
            sizes[count] = bytes.len;
            count += 1;
        };
        var format: ?*anyopaque = null;
        self.last_status = spice_zig_video_format(@intFromBool(self.codec == .h265), &ptrs, &sizes, count, &format);
        if (self.last_status != 0 or format == null) return error.UnsupportedVideoFormat;
        errdefer spice_zig_video_format_release(format.?);
        var w: i32 = 0;
        var h: i32 = 0;
        spice_zig_video_format_size(format.?, &w, &h);
        if (w != self.width or h != self.height) return error.DimensionMismatch;
        var session: ?*anyopaque = null;
        self.last_status = spice_zig_video_session(format.?, &session);
        if (self.last_status != 0 or session == null) return error.VideoSessionFailed;
        self.stats.sessions += 1;
        errdefer spice_zig_video_session_release(session.?);
        self.last_status = spice_zig_video_realtime(session.?);
        if (self.last_status != 0) return error.VideoConfigurationFailed;
        var hardware: c_int = 0;
        self.last_status = spice_zig_video_hardware(session.?, &hardware);
        if (self.last_status != 0) {
            self.stats.query_failed += 1;
            return error.VideoHardwareQueryFailed;
        }
        if (hardware != 1) {
            self.stats.software += 1;
            return error.VideoHardwareUnavailable;
        }
        self.stats.hardware += 1;
        if (self.session) |p| spice_zig_video_session_release(p);
        if (self.format) |p| spice_zig_video_format_release(p);
        self.session = session;
        self.format = format;
        self.dirty = false;
    }
    pub fn decode(self: *Decoder, payload: []const u8, time: u32, token: *cancel.Token) !?Frame {
        try token.check();
        self.mutex.lock();
        defer self.mutex.unlock();
        try token.check();
        var unit = try annex.parse(self.allocator, self.codec, payload, self.limits.parser);
        defer unit.deinit();
        try self.update(unit);
        if (self.dirty or self.format == null) try self.rebuild();
        if (!unit.picture) return null;
        if (self.session == null or self.format == null) return error.MissingParameterSets;
        if (unit.sample.len == 0) return error.EmptySample;
        const owner = try self.allocator.create(Sample);
        owner.* = .{ .allocator = self.allocator, .bytes = unit.sample };
        unit.sample = &.{}; // Ownership moves into CoreMedia on every return path.
        var pixel: ?*anyopaque = null;
        self.last_status = spice_zig_video_decode(self.session.?, self.format.?, owner.bytes.ptr, owner.bytes.len, time, owner, Sample.release, &pixel);
        if (self.last_status != 0) return error.VideoDecodeFailed;
        if (pixel) |handle| {
            const frame = try Frame.take(handle, self.width, self.height, self.limits);
            errdefer frame.deinit();
            try token.check();
            self.stats.frames += 1;
            return frame;
        }
        try token.check();
        self.stats.dropped += 1;
        return null;
    }
};
