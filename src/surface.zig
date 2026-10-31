//! Transactional Surface foundation. Immutable snapshots retain CPU/IOSurface
//! backing; candidate writes and GPU commands cannot change published pixels.
//! Store operations serialize candidate commits. Publication damage has its own
//! lifecycle owner so rollback remains safe after a Store is destroyed.
const std = @import("std");
const damage_journal = @import("damage.zig");
pub const MemoryBudget = @import("surface_budget.zig").Budget;
const sync = @import("sync.zig");
const cancel = @import("cancel.zig");
const Image = @import("image.zig").Image;
const graphics = @import("graphics.zig");
const video_codec = @import("video.zig");
const region = @import("region.zig");
pub const diagnostics = @import("surface_metrics.zig");
pub const Rect = region.Rect;
pub const Format = enum(u32) { xrgb = 32, argb = 96 };
pub const Limits = struct { dimension: usize = 16384, surface_bytes: usize = 256 * 1024 * 1024, total_bytes: usize = 256 * 1024 * 1024 };
pub const Revision = struct { id: u32, lifecycle: u64, value: u64 };
pub const Barrier = struct { id: u32, lifecycle: u64, value: u64 };
pub const Sequence = struct { id: u32, lifecycle: u64, value: u64 };
pub const Backing = union(enum) {
    cpu: Image,
    native: *graphics.Frame,
    pub fn retain(self: Backing) Backing {
        return switch (self) {
            .cpu => |image| .{ .cpu = image.retain() },
            .native => |frame| .{ .native = frame.retain() },
        };
    }
    pub fn release(self: Backing) void {
        switch (self) {
            .cpu => |image| image.release(),
            .native => |frame| frame.release(),
        }
    }
    pub const Read = struct {
        bytes: []const u8,
        stride: usize,
        mapping: ?graphics.Frame.Mapping = null,
        pub fn finish(self: Read) !void {
            if (self.mapping) |mapping| try mapping.unlock();
        }
    };
    pub fn read(self: Backing) !Read {
        return switch (self) {
            .cpu => |image| .{ .bytes = image.pixels(), .stride = image.stride },
            .native => |frame| blk: {
                const mapping = try frame.lock(false);
                break :blk .{ .bytes = mapping.bytes, .stride = mapping.stride, .mapping = mapping };
            },
        };
    }
};
pub const Snapshot = struct {
    revision: Revision,
    barrier: Barrier,
    width: usize,
    height: usize,
    format: Format,
    backing: Backing,
    damage: ?Rect,
    advanced_video: bool = false,
    pub fn deinit(self: Snapshot) void {
        self.backing.release();
    }
};
/// Shared immutable publication. Last release restores uncommitted damage;
/// commit/restore are idempotent across retained copies and serialize on the
/// damage owner's lock. Pixel leases remain independent of Store lifetime.
pub const Publication = struct {
    const Storage = struct { allocator: std.mem.Allocator, refs: std.atomic.Value(usize) = .init(1), state: enum { pending, committed, restored } = .pending, snapshot: Snapshot, damage: damage_journal.Journal, owner: *damage_journal.Owner, pixel_mutex: sync.Mutex = .{}, cached_pixels: ?Image = null, recorder: *diagnostics.Recorder };
    storage: *Storage,
    full_damage: bool = false,
    fn prepare(a: std.mem.Allocator, owner: *damage_journal.Owner, recorder: *diagnostics.Recorder, snapshot_value: Snapshot) !Publication {
        const storage = try a.create(Storage);
        owner.mutex.lock();
        defer owner.mutex.unlock();
        std.debug.assert(owner.alive);
        storage.* = .{ .allocator = a, .snapshot = snapshot_value, .damage = owner.journal, .owner = owner.retain(), .recorder = recorder.retain() };
        recorder.add("publications", 1);
        storage.snapshot.damage = owner.journal.bounding();
        owner.journal.clear();
        return .{ .storage = storage };
    }
    pub fn retain(self: Publication) Publication {
        const old = self.storage.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old > 0 and old < std.math.maxInt(usize));
        return self;
    }
    pub fn snapshot(self: Publication) *const Snapshot {
        return &self.storage.snapshot;
    }
    /// Tight, top-down immutable BGRA. CPU backing is borrowed directly;
    /// native readback is allocated once on demand and cached for this lease.
    /// Returned bytes live until the final Publication release.
    pub fn pixels(self: Publication) ![]const u8 {
        const snapshot_value = &self.storage.snapshot;
        if (snapshot_value.backing == .cpu) return snapshot_value.backing.cpu.pixels();
        self.storage.pixel_mutex.lock();
        defer self.storage.pixel_mutex.unlock();
        if (self.storage.cached_pixels) |image| return image.pixels();
        const image = try Image.create(self.storage.allocator, snapshot_value.width, snapshot_value.height, true, if (snapshot_value.format == .argb) .straight else .opaque_pixels);
        errdefer image.release();
        const source = try snapshot_value.backing.read();
        var locked = true;
        defer if (locked) source.finish() catch {};
        for (0..snapshot_value.height) |y| @memcpy(image.unpublishedPixels()[y * image.stride ..][0..image.stride], source.bytes[y * source.stride ..][0..image.stride]);
        try source.finish();
        locked = false;
        self.storage.cached_pixels = image;
        self.storage.recorder.materialized(image.stride * image.height);
        return image.pixels();
    }
    /// Copies directly into caller-owned tight BGRA storage. This boundary is
    /// for value-semantic consumers which may mutate their returned byte array;
    /// it does not allocate a second native readback cache. Caller serializes
    /// its destination and owns it through this call.
    pub fn copyPixels(self: Publication, destination: []u8) !void {
        const value = self.snapshot();
        const stride = try std.math.mul(usize, value.width, 4);
        if (destination.len != try std.math.mul(usize, stride, value.height)) return error.InvalidSize;
        self.storage.pixel_mutex.lock();
        defer self.storage.pixel_mutex.unlock();
        if (self.storage.cached_pixels) |image| {
            @memcpy(destination, image.pixels());
            return;
        }
        const source = try value.backing.read();
        var locked = true;
        defer if (locked) source.finish() catch {};
        for (0..value.height) |y| @memcpy(destination[y * stride ..][0..stride], source.bytes[y * source.stride ..][0..stride]);
        try source.finish();
        locked = false;
        if (value.backing == .native) self.storage.recorder.materialized(destination.len);
    }
    pub fn damage(self: Publication) damage_journal.Journal {
        var journal = self.storage.damage;
        if (self.full_damage) journal.markFull();
        return journal;
    }
    pub fn commit(self: Publication) void {
        const owner = self.storage.owner;
        owner.mutex.lock();
        defer owner.mutex.unlock();
        if (self.storage.state == .pending) self.storage.state = .committed;
    }
    pub fn restore(self: Publication) void {
        const owner = self.storage.owner;
        owner.mutex.lock();
        defer owner.mutex.unlock();
        if (self.storage.state != .pending) return;
        self.storage.state = .restored;
        if (owner.alive) owner.journal.merge(self.storage.damage) catch unreachable;
    }
    pub fn release(self: Publication) void {
        if (self.storage.refs.fetchSub(1, .acq_rel) == 1) {
            self.restore();
            const a = self.storage.allocator;
            if (self.storage.cached_pixels) |image| image.release();
            self.storage.pixel_mutex.deinit();
            self.storage.snapshot.deinit();
            self.storage.owner.release();
            self.storage.recorder.publicationReleased();
            self.storage.recorder.release();
            a.destroy(self.storage);
        }
    }
};
pub const Store = struct {
    const Surface = struct { width: usize, height: usize, format: Format, lifecycle: u64, revision: u64 = 0, mutation: u64 = 0, video: u64 = 0, reserved_video: u64 = 0, advanced_video: bool = false, backing: Backing, damage: *damage_journal.Owner };
    allocator: std.mem.Allocator,
    limits: Limits = .{},
    graphics: ?graphics.Context = null,
    mutex: sync.Mutex = .{},
    closed: bool = false,
    recorder: ?*diagnostics.Recorder = null,
    bytes: usize = 0,
    shared_budget: ?*MemoryBudget = null,
    native_namespace: ?u64 = null,
    native_pool: graphics.FramePool,
    surfaces: std.AutoHashMapUnmanaged(u32, Surface) = .empty,
    generations: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    pub fn init(a: std.mem.Allocator, limits: Limits, native: ?graphics.Context) Store {
        return .{ .allocator = a, .limits = limits, .graphics = native, .native_pool = .{ .allocator = a } };
    }
    pub fn create(self: *Store, id: u32, width: usize, height: usize, format: u32, token: *cancel.Token) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try token.check();
        if (self.closed) return error.Closed;
        if (self.surfaces.contains(id)) return error.DuplicateSurface;
        if (width == 0 or height == 0 or width > self.limits.dimension or height > self.limits.dimension) return error.InvalidDimensions;
        const size = try std.math.mul(usize, try std.math.mul(usize, width, height), 4);
        if (size > self.limits.surface_bytes) return error.SurfaceTooLarge;
        if (size > self.limits.total_bytes - self.bytes) return error.SurfaceBudgetExceeded;
        if (self.shared_budget) |budget| try budget.reserve(size);
        errdefer if (self.shared_budget) |budget| budget.release(size);
        const kind = std.enums.fromInt(Format, format) orelse return error.UnsupportedSurfaceFormat;
        const generation = try std.math.add(u64, self.generations.get(id) orelse 0, 1);
        if (self.recorder == null) self.recorder = try diagnostics.Recorder.create(self.allocator);
        const image = try Image.create(self.allocator, width, height, true, if (kind == .argb) .straight else .opaque_pixels);
        errdefer image.release();
        const damage_owner = try damage_journal.Owner.create(self.allocator, width, height);
        errdefer damage_owner.release();
        @memset(image.unpublishedPixels(), 0);
        try self.surfaces.ensureUnusedCapacity(self.allocator, 1);
        try self.generations.ensureUnusedCapacity(self.allocator, 1);
        try token.check();
        self.generations.putAssumeCapacity(id, generation);
        self.surfaces.putAssumeCapacity(id, .{ .width = width, .height = height, .format = kind, .lifecycle = generation, .backing = .{ .cpu = image }, .damage = damage_owner });
        self.bytes += size;
    }
    pub fn destroy(self: *Store, id: u32, token: *cancel.Token) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try token.check();
        const surface = self.surfaces.get(id) orelse return error.UnknownSurface;
        const next = try std.math.add(u64, surface.lifecycle, 1);
        self.generations.putAssumeCapacity(id, next);
        _ = self.surfaces.remove(id);
        self.bytes -= surface.width * surface.height * 4;
        surface.backing.release();
        if (self.native_namespace) |namespace| self.native_pool.retire(.{ .namespace = namespace, .surface = id });
        surface.damage.close();
        surface.damage.release();
        if (self.shared_budget) |budget| budget.release(surface.width * surface.height * 4);
    }
    pub fn close(self: *Store) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        var iterator = self.surfaces.valueIterator();
        while (iterator.next()) |surface| {
            surface.backing.release();
            surface.damage.close();
            surface.damage.release();
        }
        self.native_pool.clear();
        self.surfaces.clearRetainingCapacity();
        if (self.shared_budget) |budget| budget.release(self.bytes);
        self.bytes = 0;
    }
    pub fn deinit(self: *Store) void {
        self.close();
        self.native_pool.deinit();
        self.surfaces.deinit(self.allocator);
        self.generations.deinit(self.allocator);
        if (self.recorder) |recorder| recorder.release();
        self.mutex.deinit();
    }
    pub fn metrics(self: *Store) diagnostics.Metrics {
        self.mutex.lock();
        defer self.mutex.unlock();
        var value = if (self.recorder) |recorder| recorder.snapshot() else diagnostics.Metrics{};
        value.native_enabled = self.graphics != null;
        for (self.native_pool.slots.items) |frame| {
            value.allocated_frames += 1;
            value.allocated_bytes += frame.allocation_bytes;
            if (frame.refs.load(.acquire) > 1) value.pool_in_use += 1;
        }
        if (self.graphics) |context| {
            const memory = context.memory();
            value.recommended_working_set = memory.recommended;
            value.metal_allocated_bytes = memory.allocated;
        }
        return value;
    }
    pub fn snapshot(self: *Store, id: u32) !Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        const surface = self.surfaces.get(id) orelse return error.UnknownSurface;
        self.recorder.?.add("snapshots", 1);
        return .{ .revision = .{ .id = id, .lifecycle = surface.lifecycle, .value = surface.revision }, .barrier = .{ .id = id, .lifecycle = surface.lifecycle, .value = surface.mutation }, .width = surface.width, .height = surface.height, .format = surface.format, .backing = surface.backing.retain(), .damage = surface.damage.snapshot().bounding(), .advanced_video = surface.advanced_video };
    }
    pub fn publicationSnapshot(self: *Store, requested: Revision) !?Publication {
        self.mutex.lock();
        defer self.mutex.unlock();
        const surface = self.surfaces.get(requested.id) orelse return null;
        if (self.closed or surface.lifecycle != requested.lifecycle or surface.revision < requested.value) return null;
        const snapshot_value: Snapshot = .{ .revision = .{ .id = requested.id, .lifecycle = surface.lifecycle, .value = surface.revision }, .barrier = .{ .id = requested.id, .lifecycle = surface.lifecycle, .value = surface.mutation }, .width = surface.width, .height = surface.height, .format = surface.format, .backing = surface.backing.retain(), .damage = surface.damage.snapshot().bounding(), .advanced_video = surface.advanced_video };
        errdefer snapshot_value.deinit();
        const result = try Publication.prepare(self.allocator, surface.damage, self.recorder.?, snapshot_value);
        self.recorder.?.add("snapshots", 1);
        return result;
    }
    pub fn acknowledgeDamage(self: *Store, revision: Revision) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.surfaces.getPtr(revision.id)) |surface| if (surface.lifecycle == revision.lifecycle and surface.revision == revision.value) {
            surface.damage.clear();
        };
    }
    fn candidate(self: *Store, surface: Surface, token: *cancel.Token) !Image {
        try token.check();
        const image = try Image.create(self.allocator, surface.width, surface.height, true, if (surface.format == .argb) .straight else .opaque_pixels);
        errdefer image.release();
        const source = try surface.backing.read();
        var locked = true;
        defer if (locked) source.finish() catch {};
        const output = image.unpublishedPixels();
        for (0..surface.height) |y| {
            try token.check();
            @memcpy(output[y * image.stride ..][0..image.stride], source.bytes[y * source.stride ..][0..image.stride]);
        }
        try source.finish();
        locked = false;
        self.recorder.?.add("full_copy_bytes", image.stride * image.height);
        if (surface.backing == .native) self.recorder.?.materialized(image.stride * image.height);
        return image;
    }
    fn validateRegion(surface: Surface, rectangles: []const Rect) !void {
        if (rectangles.len > 65536) return error.SegmentLimit;
        for (rectangles) |r| try r.validate(surface.width, surface.height);
    }
    fn damage(surface: *Surface, rectangles: []const Rect) void {
        surface.damage.append(rectangles);
    }
    fn commit(self: *Store, id: u32, surface: *Surface, backing: Backing, rectangles: []const Rect, video: ?Sequence, advanced: bool) !Revision {
        const revision = try std.math.add(u64, surface.revision, 1);
        const mutation = if (video != null) surface.mutation else try std.math.add(u64, surface.mutation, 1);
        surface.backing.release();
        surface.backing = backing;
        surface.revision = revision;
        surface.advanced_video = advanced;
        surface.mutation = mutation;
        if (video) |sequence| surface.video = sequence.value;
        damage(surface, rectangles);
        const recorder = self.recorder.?;
        recorder.mutex.lock();
        for (rectangles) |r| {
            recorder.value.damage_operations +|= 1;
            recorder.value.damage_bytes +|= @as(u64, @intCast(r.width)) * @as(u64, @intCast(r.height)) * 4;
        }
        recorder.mutex.unlock();
        return .{ .id = id, .lifecycle = surface.lifecycle, .value = revision };
    }
    pub fn fill(self: *Store, id: u32, rectangles: []const Rect, color_argb: u32, token: *cancel.Token) !?Revision {
        if (rectangles.len == 0) return null;
        self.mutex.lock();
        defer self.mutex.unlock();
        const surface = self.surfaces.getPtr(id) orelse return error.UnknownSurface;
        try validateRegion(surface.*, rectangles);
        const candidate_image = try self.candidate(surface.*, token);
        errdefer candidate_image.release();
        const output = candidate_image.unpublishedPixels();
        const color = if (surface.format == .argb) color_argb else color_argb | 0xff000000;
        for (rectangles) |r| {
            for (@intCast(r.y)..@intCast(r.y + r.height)) |y| {
                try token.check();
                for (@intCast(r.x)..@intCast(r.x + r.width)) |x| std.mem.writeInt(u32, output[y * candidate_image.stride + x * 4 ..][0..4], color, .little);
            }
        }
        try token.check();
        return try self.commit(id, surface, .{ .cpu = candidate_image }, rectangles, null, false);
    }
    fn translated(r: Rect, destination: Rect, source: Rect) !Rect {
        if (destination.width != source.width or destination.height != source.height or destination.width <= 0 or destination.height <= 0) return error.InvalidGeometry;
        if (r.x < destination.x or r.y < destination.y or try r.right() > try destination.right() or try r.bottom() > try destination.bottom()) return error.InvalidGeometry;
        return .{ .x = try std.math.add(i64, source.x, try std.math.sub(i64, r.x, destination.x)), .y = try std.math.add(i64, source.y, try std.math.sub(i64, r.y, destination.y)), .width = r.width, .height = r.height };
    }
    pub fn copyBits(self: *Store, id: u32, rectangles: []const Rect, destination: Rect, source: Rect, token: *cancel.Token) !?Revision {
        return self.copySurface(id, id, rectangles, destination, source, token);
    }
    pub fn copySurface(self: *Store, id: u32, source_id: u32, rectangles: []const Rect, destination: Rect, source_rect: Rect, token: *cancel.Token) !?Revision {
        if (rectangles.len == 0) return null;
        self.mutex.lock();
        defer self.mutex.unlock();
        const surface = self.surfaces.getPtr(id) orelse return error.UnknownSurface;
        const source = self.surfaces.get(source_id) orelse return error.UnknownSurface;
        try validateRegion(surface.*, rectangles);
        for (rectangles) |r| try (try translated(r, destination, source_rect)).validate(source.width, source.height);
        const input = try source.backing.read();
        var locked = true;
        defer if (locked) input.finish() catch {};
        const candidate_image = try self.candidate(surface.*, token);
        errdefer candidate_image.release();
        const output = candidate_image.unpublishedPixels();
        for (rectangles) |r| {
            const src = try translated(r, destination, source_rect);
            for (0..@intCast(r.height)) |row| {
                try token.check();
                const from = (@as(usize, @intCast(src.y)) + row) * input.stride + @as(usize, @intCast(src.x)) * 4;
                const to = (@as(usize, @intCast(r.y)) + row) * candidate_image.stride + @as(usize, @intCast(r.x)) * 4;
                const count = @as(usize, @intCast(r.width)) * 4;
                @memcpy(output[to..][0..count], input.bytes[from..][0..count]);
            }
        }
        try input.finish();
        locked = false;
        try token.check();
        return try self.commit(id, surface, .{ .cpu = candidate_image }, rectangles, null, false);
    }
    pub fn copyImage(self: *Store, id: u32, rectangles: []const Rect, destination: Rect, source_rect: Rect, image: Image, token: *cancel.Token) !?Revision {
        if (rectangles.len == 0) return null;
        self.mutex.lock();
        defer self.mutex.unlock();
        const surface = self.surfaces.getPtr(id) orelse return error.UnknownSurface;
        try validateRegion(surface.*, rectangles);
        for (rectangles) |r| try (try translated(r, destination, source_rect)).validate(image.width, image.height);
        const candidate_image = try self.candidate(surface.*, token);
        errdefer candidate_image.release();
        const output = candidate_image.unpublishedPixels();
        const input = image.pixels();
        for (rectangles) |r| {
            const src = try translated(r, destination, source_rect);
            for (0..@intCast(r.height)) |row| {
                try token.check();
                const sy = @as(usize, @intCast(src.y)) + row;
                const physical = if (image.top_down) sy else image.height - 1 - sy;
                const from = physical * image.stride + @as(usize, @intCast(src.x)) * 4;
                const to = (@as(usize, @intCast(r.y)) + row) * candidate_image.stride + @as(usize, @intCast(r.x)) * 4;
                for (0..@intCast(r.width)) |x| {
                    var color = std.mem.readInt(u32, input[from + x * 4 ..][0..4], .little);
                    if (surface.format != .argb or image.alpha == .opaque_pixels) color |= 0xff000000;
                    std.mem.writeInt(u32, output[to + x * 4 ..][0..4], color, .little);
                }
            }
        }
        try token.check();
        return try self.commit(id, surface, .{ .cpu = candidate_image }, rectangles, null, false);
    }
    pub const VideoAdmission = struct { barrier: Barrier, sequence: Sequence, width: usize, height: usize };
    /// Global per-Surface order across all streams, captured with the mutation
    /// barrier at arrival. Reservation alone never changes published pixels.
    pub fn admitVideo(self: *Store, id: u32) !VideoAdmission {
        self.mutex.lock();
        defer self.mutex.unlock();
        const surface = self.surfaces.getPtr(id) orelse return error.UnknownSurface;
        const next = try std.math.add(u64, @max(surface.reserved_video, surface.video), 1);
        surface.reserved_video = next;
        return .{ .barrier = .{ .id = id, .lifecycle = surface.lifecycle, .value = surface.mutation }, .sequence = .{ .id = id, .lifecycle = surface.lifecycle, .value = next }, .width = surface.width, .height = surface.height };
    }
    pub fn drawScaledVideo(self: *Store, id: u32, source: Image, advanced: bool, source_rect: Rect, destination: Rect, rectangles: []const Rect, flip: bool, barrier: Barrier, sequence: Sequence, token: *cancel.Token) !?Revision {
        self.mutex.lock();
        defer self.mutex.unlock();
        try token.check();
        const surface = self.surfaces.getPtr(id) orelse return error.UnknownSurface;
        if (!current(surface.*, id, barrier, sequence) or rectangles.len == 0) return null;
        try validateRegion(surface.*, rectangles);
        try source_rect.validate(source.width, source.height);
        try destination.validate(surface.width, surface.height);
        for (rectangles) |r| if (r.x < destination.x or r.y < destination.y or try r.right() > try destination.right() or try r.bottom() > try destination.bottom()) return error.InvalidGeometry;
        const candidate_image = try self.candidate(surface.*, token);
        errdefer candidate_image.release();
        const output = candidate_image.unpublishedPixels();
        const input = source.pixels();
        for (rectangles) |r| {
            for (@intCast(r.y)..@intCast(r.y + r.height)) |y| {
                try token.check();
                const sy = @as(usize, @intCast(source_rect.y)) + (@as(usize, @intCast(@as(i64, @intCast(y)) - destination.y)) * @as(usize, @intCast(source_rect.height))) / @as(usize, @intCast(destination.height));
                const physical = if (flip) source.height - 1 - sy else sy;
                for (@intCast(r.x)..@intCast(r.x + r.width)) |x| {
                    const sx = @as(usize, @intCast(source_rect.x)) + (@as(usize, @intCast(@as(i64, @intCast(x)) - destination.x)) * @as(usize, @intCast(source_rect.width))) / @as(usize, @intCast(destination.width));
                    const from = physical * source.stride + sx * 4;
                    const to = y * candidate_image.stride + x * 4;
                    @memcpy(output[to..][0..4], input[from..][0..4]);
                    if (surface.format != .argb or source.alpha == .opaque_pixels) output[to + 3] = 255;
                }
            }
        }
        try token.check();
        return try self.commit(id, surface, .{ .cpu = candidate_image }, rectangles, sequence, advanced);
    }
    fn current(surface: Surface, id: u32, barrier: Barrier, sequence: Sequence) bool {
        return barrier.id == id and barrier.lifecycle == surface.lifecycle and barrier.value == surface.mutation and sequence.id == id and sequence.lifecycle == surface.lifecycle and sequence.value > surface.video;
    }
    pub fn drawNativeVideo(self: *Store, id: u32, source: anytype, source_rect: Rect, destination: Rect, rectangles: []const Rect, flip: bool, barrier: Barrier, sequence: Sequence, token: *cancel.Token) !?Revision {
        self.mutex.lock();
        defer self.mutex.unlock();
        try token.check();
        const surface = self.surfaces.getPtr(id) orelse return error.UnknownSurface;
        if (!current(surface.*, id, barrier, sequence)) return null;
        if (rectangles.len == 0) return null;
        const context = self.graphics orelse return error.MetalUnavailable;
        try validateRegion(surface.*, rectangles);
        try source_rect.validate(source.width, source.height);
        try destination.validate(surface.width, surface.height);
        if (self.native_namespace == null) self.native_namespace = try graphics.newNamespace();
        const candidate_frame = self.native_pool.checkout(context, surface.width, surface.height, .{ .namespace = self.native_namespace.?, .surface = id }) catch |err| {
            if (err == error.NativePoolExhausted) self.recorder.?.add("pool_exhaustions", 1);
            return err;
        };

        errdefer {
            self.native_pool.discard(candidate_frame);
            candidate_frame.release();
        }
        switch (surface.backing) {
            .native => |frame| {
                context.copy(frame, candidate_frame, token) catch |err| {
                    if (err == error.GPUFailed) self.recorder.?.add("gpu_errors", 1);
                    return err;
                };
                self.recorder.?.add("gpu_copy_bytes", surface.width * surface.height * 4);
            },
            .cpu => |image| {
                const mapping = try candidate_frame.lock(true);
                var locked = true;
                defer if (locked) mapping.unlock() catch {};
                for (0..surface.height) |y| @memcpy(mapping.bytes[y * mapping.stride ..][0..image.stride], image.pixels()[y * image.stride ..][0..image.stride]);
                try mapping.unlock();
                locked = false;
                self.recorder.?.add("direct_native_write_bytes", surface.width * surface.height * 4);
                self.recorder.?.add("full_copy_bytes", surface.width * surface.height * 4);
            },
        }
        if (comptime @TypeOf(source) == video_codec.Frame) {
            context.composeVideo(source, candidate_frame, source_rect, destination, rectangles, flip, token) catch |err| {
                if (err == error.GPUFailed) self.recorder.?.add("gpu_errors", 1);
                return err;
            };
        } else {
            context.compose(source, candidate_frame, source_rect, destination, rectangles, flip, token) catch |err| {
                if (err == error.GPUFailed) self.recorder.?.add("gpu_errors", 1);
                return err;
            };
        }
        try token.check();
        const result = try self.commit(id, surface, .{ .native = candidate_frame }, rectangles, sequence, @TypeOf(source) == video_codec.Frame);
        self.recorder.?.add("native_video_frames", 1);
        return result;
    }
};
