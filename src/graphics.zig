//! Apple native frame ownership. Handles are retained independently of Context.
//! Commands are synchronous fences: callers retain both frames until completion,
//! and must only publish a destination after success. No eager CPU readback.
const std = @import("std");
const Rect = @import("region.zig").Rect;
const cancel = @import("cancel.zig");
const sync = @import("sync.zig");
const video = @import("video.zig");
extern "c" fn spice_zig_graphics_compose_video(*anyopaque, *anyopaque, *anyopaque, *const [32]u32) c_int;
extern "c" fn spice_zig_graphics_create([*:0]const u8) ?*anyopaque;
extern "c" fn spice_zig_graphics_submitted(*anyopaque) u64;
extern "c" fn spice_zig_graphics_retain(*anyopaque) void;
extern "c" fn spice_zig_graphics_destroy(*anyopaque) void;
extern "c" fn spice_zig_graphics_frame_layout(u32, u32, *usize, *usize) c_int;
extern "c" fn spice_zig_graphics_frame_size(*anyopaque) usize;
extern "c" fn spice_zig_graphics_frame_create(*anyopaque, u32, u32) ?*anyopaque;
extern "c" fn spice_zig_graphics_frame_destroy(*anyopaque) void;
extern "c" fn spice_zig_graphics_frame_lock(*anyopaque, c_int, *?[*]u8, *usize, *usize) c_int;
extern "c" fn spice_zig_graphics_frame_unlock(*anyopaque, c_int) c_int;
extern "c" fn spice_zig_graphics_frame_texture(*anyopaque) ?*anyopaque;
extern "c" fn spice_zig_graphics_frame_surface(*anyopaque) ?*anyopaque;
extern "c" fn spice_zig_graphics_copy(*anyopaque, *anyopaque, *anyopaque) c_int;
extern "c" fn spice_zig_graphics_compose_bgra(*anyopaque, *anyopaque, *anyopaque, *const [12]u32, c_int) c_int;
extern "c" fn spice_zig_graphics_lanczos(*anyopaque, *anyopaque, *anyopaque) c_int;
extern "c" fn spice_zig_graphics_memory(*anyopaque, *u64, *u64) void;
pub const Owner = struct { namespace: u64, surface: u32 };
/// All default contexts share this process-wide native allocation budget.
/// A retained frame owns its charge after resize/retire/context destruction.
pub const Budget = struct {
    mutex: sync.Mutex = .{},
    maximum: usize = 256 * 1024 * 1024,
    per_surface: usize = 3,
    bytes: usize = 0,
    frames: usize = 0,
    owners: std.AutoHashMapUnmanaged(Owner, usize) = .empty,
    pub fn reserve(self: *Budget, owner: ?Owner, bytes: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (bytes > self.maximum - self.bytes) return error.NativeBudgetExceeded;
        if (owner) |key| {
            if ((self.owners.get(key) orelse 0) >= self.per_surface) return error.NativePoolExhausted;
            const entry = try self.owners.getOrPut(std.heap.c_allocator, key);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
        }
        self.bytes += bytes;
        self.frames += 1;
    }
    fn release(self: *Budget, owner: ?Owner, bytes: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.bytes -= bytes;
        self.frames -= 1;
        if (owner) |key| {
            const count = self.owners.getPtr(key).?;
            count.* -= 1;
            if (count.* == 0) _ = self.owners.remove(key);
        }
    }
    pub fn snapshot(self: *Budget) struct { bytes: usize, frames: usize } {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .bytes = self.bytes, .frames = self.frames };
    }
    pub fn deinit(self: *Budget) void {
        std.debug.assert(self.frames == 0 and self.bytes == 0);
        self.owners.deinit(std.heap.c_allocator);
        self.mutex.deinit();
    }
};
var shared_budget: Budget = .{};
pub fn allocatedBytes() usize {
    return shared_budget.snapshot().bytes;
}
var namespace_mutex: sync.Mutex = .{};
var next_namespace: u64 = 0;
pub fn newNamespace() !u64 {
    namespace_mutex.lock();
    defer namespace_mutex.unlock();
    next_namespace = try std.math.add(u64, next_namespace, 1);
    return next_namespace;
}
pub const Frame = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    handle: *anyopaque,
    budget: *Budget,
    owner: ?Owner,
    allocation_bytes: usize,
    width: usize,
    height: usize,
    pub fn retain(self: *Frame) *Frame {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old > 0 and old < std.math.maxInt(usize));
        return self;
    }
    pub fn release(self: *Frame) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            spice_zig_graphics_frame_destroy(self.handle);
            self.budget.release(self.owner, self.allocation_bytes);
            self.allocator.destroy(self);
        }
    }
    pub fn texture(self: *Frame) ?*anyopaque {
        return spice_zig_graphics_frame_texture(self.handle);
    }
    pub fn surface(self: *Frame) ?*anyopaque {
        return spice_zig_graphics_frame_surface(self.handle);
    }
    pub const Mapping = struct {
        frame: *Frame,
        bytes: []u8,
        stride: usize,
        writing: bool,
        pub fn unlock(self: Mapping) !void {
            if (spice_zig_graphics_frame_unlock(self.frame.handle, @intFromBool(self.writing)) != 0) return error.IOSurfaceUnlockFailed;
        }
    };
    /// Caller holds a frame reference, with no concurrent writer/GPU operation.
    pub fn lock(self: *Frame, writing: bool) !Mapping {
        var data: ?[*]u8 = null;
        var stride: usize = 0;
        var size: usize = 0;
        if (spice_zig_graphics_frame_lock(self.handle, @intFromBool(writing), &data, &stride, &size) != 0) return error.IOSurfaceLockFailed;
        errdefer _ = spice_zig_graphics_frame_unlock(self.handle, @intFromBool(writing));
        if (stride < try std.math.mul(usize, self.width, 4) or size < try std.math.mul(usize, stride, self.height) or data == null) return error.InvalidNativeFrame;
        return .{ .frame = self, .bytes = data.?[0..size], .stride = stride, .writing = writing };
    }
};
/// Serialized by the owning Store. One reference belongs to the pool; only
/// slots with no external/canonical/writer reference may be checked out. All
/// native commands fence before their writer releases, including failure paths.
/// Retiring drops pool ownership; outstanding snapshots keep their budget charge.
pub const FramePool = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayList(*Frame) = .empty,
    allocations: u64 = 0,
    reuses: u64 = 0,
    pub fn checkout(self: *FramePool, context: Context, width: usize, height: usize, owner: Owner) !*Frame {
        for (self.slots.items) |frame| {
            if (std.meta.eql(frame.owner, @as(?Owner, owner)) and frame.width == width and frame.height == height and frame.refs.load(.acquire) == 1) {
                self.reuses +|= 1;
                return frame.retain();
            }
        }
        try self.slots.ensureUnusedCapacity(self.allocator, 1);
        const frame = try context.createOwned(self.allocator, width, height, owner);
        self.slots.appendAssumeCapacity(frame);
        self.allocations +|= 1;
        return frame.retain();
    }
    /// A failed command's target leaves the ring instead of retaining a
    /// potentially unusable driver allocation or a cancellation-only charge.
    pub fn discard(self: *FramePool, frame: *Frame) void {
        for (self.slots.items, 0..) |slot, index| if (slot == frame) {
            _ = self.slots.swapRemove(index);
            slot.release();
            return;
        };
    }
    pub fn retire(self: *FramePool, owner: Owner) void {
        var index: usize = 0;
        while (index < self.slots.items.len) {
            const frame = self.slots.items[index];
            if (std.meta.eql(frame.owner, @as(?Owner, owner))) {
                _ = self.slots.swapRemove(index);
                frame.release();
            } else index += 1;
        }
    }
    pub fn clear(self: *FramePool) void {
        for (self.slots.items) |frame| frame.release();
        self.slots.clearRetainingCapacity();
    }
    pub fn deinit(self: *FramePool) void {
        self.clear();
        self.slots.deinit(self.allocator);
    }
};
pub const Context = struct {
    handle: *anyopaque,
    budget: *Budget = &shared_budget,
    test_failure_after_completion: if (@import("builtin").is_test) bool else void = if (@import("builtin").is_test) false else {},
    pub fn memory(self: Context) struct { recommended: u64, allocated: u64 } {
        var recommended: u64 = 0;
        var allocated: u64 = 0;
        spice_zig_graphics_memory(self.handle, &recommended, &allocated);
        return .{ .recommended = recommended, .allocated = allocated };
    }
    pub fn submitted(self: Context) u64 {
        return spice_zig_graphics_submitted(self.handle);
    }
    fn completed(self: Context, token: *cancel.Token) !void {
        try token.check();
        if (comptime @import("builtin").is_test) {
            if (self.test_failure_after_completion) return error.GPUFailed;
        }
    }

    pub fn init(metallib: [*:0]const u8) !Context {
        return .{ .handle = spice_zig_graphics_create(metallib) orelse return error.MetalUnavailable };
    }
    /// Retains Apple objects; a custom Budget must still outlive every frame.
    pub fn retain(self: Context) Context {
        spice_zig_graphics_retain(self.handle);
        return self;
    }
    pub fn deinit(self: Context) void {
        spice_zig_graphics_destroy(self.handle);
    }
    pub fn create(self: Context, a: std.mem.Allocator, width: usize, height: usize) !*Frame {
        return self.createOwned(a, width, height, null);
    }
    pub fn createOwned(self: Context, a: std.mem.Allocator, width: usize, height: usize, owner: ?Owner) !*Frame {
        if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.InvalidDimensions;
        var stride: usize = 0;
        var size: usize = 0;
        if (spice_zig_graphics_frame_layout(@intCast(width), @intCast(height), &stride, &size) != 0) return error.InvalidNativeFrame;
        try self.budget.reserve(owner, size);
        errdefer self.budget.release(owner, size);
        const frame = try a.create(Frame);
        errdefer a.destroy(frame);
        const handle = spice_zig_graphics_frame_create(self.handle, @intCast(width), @intCast(height)) orelse return error.NativeAllocationFailed;
        errdefer spice_zig_graphics_frame_destroy(handle);
        if (spice_zig_graphics_frame_size(handle) != size) return error.UnexpectedNativeAllocationSize;
        frame.* = .{ .allocator = a, .handle = handle, .width = width, .height = height, .budget = self.budget, .owner = owner, .allocation_bytes = size };
        return frame;
    }
    pub fn copy(self: Context, source: *Frame, destination: *Frame, token: *cancel.Token) !void {
        try token.check();
        if (source.width != destination.width or source.height != destination.height or source == destination) return error.InvalidGeometry;
        if (spice_zig_graphics_copy(self.handle, source.handle, destination.handle) != 0) return error.GPUFailed;
        try self.completed(token);
    }
    pub fn compose(self: Context, source: *Frame, destination: *Frame, source_rect: Rect, destination_rect: Rect, clips: []const Rect, flip: bool, token: *cancel.Token) !void {
        try token.check();
        try source_rect.validate(source.width, source.height);
        try destination_rect.validate(destination.width, destination.height);
        if (source == destination) return error.InvalidGeometry;
        if (clips.len > 65536) return error.ClipLimit;
        // Validate all dispatches before encoding the first command. The caller
        // owns an unpublished candidate, so a later driver failure is discarded.
        for (clips) |clip| {
            try clip.validate(destination.width, destination.height);
            if (clip.x < destination_rect.x or clip.y < destination_rect.y or try clip.right() > try destination_rect.right() or try clip.bottom() > try destination_rect.bottom()) return error.InvalidGeometry;
        }
        for (clips) |clip| {
            try token.check();
            const rects = [12]u32{ @intCast(source_rect.x), @intCast(source_rect.y), @intCast(source_rect.width), @intCast(source_rect.height), @intCast(destination_rect.x), @intCast(destination_rect.y), @intCast(destination_rect.width), @intCast(destination_rect.height), @intCast(clip.x), @intCast(clip.y), @intCast(clip.width), @intCast(clip.height) };
            if (spice_zig_graphics_compose_bgra(self.handle, source.handle, destination.handle, &rects, @intFromBool(flip)) != 0) return error.GPUFailed;
        }
        try self.completed(token);
    }
    pub fn composeVideo(self: Context, source: video.Frame, destination: *Frame, source_rect: Rect, destination_rect: Rect, clips: []const Rect, flip: bool, token: *cancel.Token) !void {
        try token.check();
        try source_rect.validate(source.width, source.height);
        try destination_rect.validate(destination.width, destination.height);
        if (source.format == .unsupported) return error.UnsupportedPixelFormat;
        if (source.format == .nv12 and (source.width % 2 != 0 or source.height % 2 != 0)) return error.UnsupportedPlaneGeometry;
        if (clips.len > 65536) return error.ClipLimit;
        var uniforms: [32]u32 = @splat(0);
        uniforms[0] = @intCast(source.width);
        uniforms[1] = @intCast(source.height);
        uniforms[2] = @intFromBool(flip);
        if (source.format == .nv12) {
            const range: [4]f32 = switch (source.range) {
                .video => .{ 16.0 / 255.0, 255.0 / 219.0, 128.0 / 255.0, 255.0 / 224.0 },
                .full => .{ 0, 1, 128.0 / 255.0, 1 },
                .unknown => return error.UnsupportedColorRange,
            };
            const colors: [12]f32 = switch (source.matrix) {
                .bt601 => .{ 1, 0, 1.402, 0, 1, -0.344136, -0.714136, 0, 1, 1.772, 0, 0 },
                .bt709 => .{ 1, 0, 1.5748, 0, 1, -0.187324, -0.468124, 0, 1, 1.8556, 0, 0 },
                .unknown => return error.UnsupportedColorMatrix,
            };
            for (range, 0..) |value, i| uniforms[16 + i] = @bitCast(value);
            for (colors, 0..) |value, i| uniforms[20 + i] = @bitCast(value);
        }
        for (clips) |clip| {
            try clip.validate(destination.width, destination.height);
            if (clip.x < destination_rect.x or clip.y < destination_rect.y or try clip.right() > try destination_rect.right() or try clip.bottom() > try destination_rect.bottom()) return error.InvalidGeometry;
        }
        for (clips) |clip| {
            try token.check();
            const rectangles = [_]Rect{ source_rect, destination_rect, clip };
            for (rectangles, 0..) |r, i| {
                const offset = (i + 1) * 4;
                uniforms[offset] = @intCast(r.x);
                uniforms[offset + 1] = @intCast(r.y);
                uniforms[offset + 2] = @intCast(r.width);
                uniforms[offset + 3] = @intCast(r.height);
            }
            if (spice_zig_graphics_compose_video(self.handle, source.handle, destination.handle, &uniforms) != 0) return error.GPUFailed;
        }
        try self.completed(token);
    }
    /// Preserve the presenter's integer nearest/fractional Lanczos policy.
    pub fn scaleForPresentation(self: Context, source: *Frame, destination: *Frame, token: *cancel.Token) !void {
        try token.check();
        if (source == destination) return error.InvalidGeometry;
        if (destination.width >= source.width and destination.height >= source.height and destination.width % source.width == 0 and destination.height % source.height == 0) {
            const rect: Rect = .{ .x = 0, .y = 0, .width = @intCast(destination.width), .height = @intCast(destination.height) };
            try self.compose(source, destination, .{ .x = 0, .y = 0, .width = @intCast(source.width), .height = @intCast(source.height) }, rect, &.{rect}, false, token);
        } else if (spice_zig_graphics_lanczos(self.handle, source.handle, destination.handle) != 0) return error.GPUFailed;
        try self.completed(token);
    }
};
