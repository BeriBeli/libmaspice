//! Display draw execution slice, with real shared GLZ/cache and Surface state.
//! DisplayService owns stream scheduling and monitors; DesktopChild assembles
//! the known child protocols. The production application has not switched yet.
const std = @import("std");
const wire = @import("bytes.zig");
const protocol = @import("display_wire.zig");
const region = @import("region.zig");
const surface = @import("surface.zig");
const cache = @import("image_cache.zig");
const glz = @import("glz.zig");
const pool = @import("codec_executor.zig");
const Image = @import("image.zig").Image;
const cancel = @import("cancel.zig");
const channel = @import("channel.zig");
const barriers = @import("barrier.zig");
const native = @import("native_codecs.zig");
const lz = @import("lz.zig");
const zlib = @import("zlib.zig");
pub const Event = union(enum) {
    created: u32,
    destroyed: u32,
    frame: surface.Revision,
    ignored: u16,
    pub fn deinit(_: Event) void {}
    pub fn weight(_: Event) usize {
        return 0;
    }
};
pub const World = struct {
    allocator: std.mem.Allocator,
    executor: pool.Executor = .{},
    surface_memory: surface.MemoryBudget = .{},
    images: cache.Cache,
    dictionary: glz.Decoder,
    pub fn create(a: std.mem.Allocator) !*World {
        const self = try a.create(World);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .images = try cache.Cache.init(a, .{}), .dictionary = undefined };
        self.dictionary = glz.Decoder.init(a, &self.executor, .{});
        return self;
    }
    pub fn destroy(self: *World) void {
        self.dictionary.deinit();
        self.images.deinit();
        self.executor.deinit();
        self.surface_memory.deinit();
        self.allocator.destroy(self);
    }
};
pub const State = struct {
    allocator: std.mem.Allocator,
    world: *World,
    surfaces: surface.Store,
    palettes: std.AutoHashMapUnmanaged(u64, []u32) = .empty,
    initialized: bool = false,
    pub fn init(a: std.mem.Allocator, world: *World, native_context: ?@import("graphics.zig").Context) State {
        var store = surface.Store.init(a, .{}, native_context);
        store.shared_budget = &world.surface_memory;
        return .{ .allocator = a, .world = world, .surfaces = store };
    }
    pub fn deinit(self: *State) void {
        self.clearPalettes();
        self.palettes.deinit(self.allocator);
        self.surfaces.deinit();
    }
    fn clearPalettes(self: *State) void {
        var iterator = self.palettes.valueIterator();
        while (iterator.next()) |entries| self.allocator.free(entries.*);
        self.palettes.clearRetainingCapacity();
    }
    pub fn step(self: *State, connection: *channel.Channel, token: *cancel.Token) !union(enum) { event: Event, migration: ?wire.Slice } {
        try token.check();
        try self.initialize(connection);
        const event = try connection.receive();
        switch (event) {
            .migration => |data| return .{ .migration = data },
            .message => |message| {
                defer message.deinit();
                const output: Event = if (try @import("channel_control.zig").handle(self.allocator, connection, message.kind, message.body.bytes())) .{ .ignored = message.kind } else try self.handle(message.kind, message.body.bytes(), message.body.retainedBytes(), connection.barrier, token);
                try connection.complete();
                return .{ .event = output };
            },
        }
    }
    pub fn initialize(self: *State, connection: *channel.Channel) !void {
        if (!self.initialized) {
            var out: wire.Writer = .{ .allocator = self.allocator, .limit = 14 };
            defer out.deinit();
            const init_message: @import("generated.zig").SpiceMsgcDisplayInit = .{ .pixmapCacheID = 1, .pixmapCacheSize = 16 * 1024 * 1024, .glzDictionaryID = 1, .glzDictionaryWindowSize = 8 * 1024 * 1024 };
            try init_message.encode(&out);
            try connection.send(101, out.bytes.items);
            self.initialized = true;
        }
    }
    const Wait = struct {
        barrier: *barriers.Barrier,
        token: barriers.Token = .{},
        fn wake(p: *anyopaque) void {
            const self: *Wait = @ptrCast(@alignCast(p));
            self.barrier.cancel(&self.token);
        }
    };
    pub fn handle(self: *State, kind: u16, body: []const u8, retained: usize, barrier: ?*barriers.Barrier, token: *cancel.Token) !Event {
        try token.check();
        var parsed = try protocol.decode(self.allocator, kind, body);
        defer parsed.deinit();
        switch (parsed.command) {
            .create => |value| {
                try self.surfaces.create(value.id, value.width, value.height, value.format, token);
                return .{ .created = value.id };
            },
            .destroy => |id| {
                try self.surfaces.destroy(id, token);
                return .{ .destroyed = id };
            },
            .reset => self.clearPalettes(),
            .invalidate => |ids| {
                for (ids) |id| self.world.images.invalidate(id);
            },
            .invalidate_all => |requirements| {
                if (requirements.len != 0) {
                    var wait: Wait = .{ .barrier = barrier orelse return error.MissingBarrier };
                    var registration: cancel.Registration = .{ .context = &wait, .wake = Wait.wake };
                    token.register(&registration);
                    defer token.unregister(&registration);
                    try wait.barrier.wait(requirements, &wait.token);
                }
                try token.check();
                self.world.images.invalidateAll();
            },
            .invalidate_palette => |id| {
                if (self.palettes.fetchRemove(id)) |entry| self.allocator.free(entry.value);
            },
            .invalidate_palettes => self.clearPalettes(),
            .copy_bits => |copy| {
                var clips = try self.makeRegion(copy.base);
                defer clips.deinit();
                const box = copy.base.box;
                const source: region.Rect = .{ .x = copy.source.x, .y = copy.source.y, .width = box.width, .height = box.height };
                if (try self.surfaces.copyBits(copy.base.surface, clips.rectangles.items, box, source, token)) |revision| return .{ .frame = revision };
            },
            .fill => |fill| {
                if (fill.rop != 8 or fill.mask.image != null or fill.brush != .solid) return error.UnsupportedDrawFill;
                var clips = try self.makeRegion(fill.base);
                defer clips.deinit();
                if (try self.surfaces.fill(fill.base.surface, clips.rectangles.items, fill.brush.solid, token)) |revision| return .{ .frame = revision };
            },
            .copy => |copy| {
                if (copy.rop != 8 or copy.mask.image != null or copy.base.box.width != copy.area.width or copy.base.box.height != copy.area.height) return error.UnsupportedDrawCopy;
                const descriptor = copy.source.descriptor;
                const flags = descriptor.flags & 5;
                const reference = copy.source.payload == .cached or copy.source.payload == .surface;
                if (flags == 5 or (reference and flags != 0)) return error.InvalidCacheFlags;
                const mutation: ?cache.Mutation = if (flags != 0) try self.world.images.begin(descriptor.id, copy.source.payload == .jpeg, if (flags == 1) .cache else .replace, retained, token) else null;
                defer if (mutation) |m| self.world.images.abort(m);
                var clips = try self.makeRegion(copy.base);
                defer clips.deinit();
                if (copy.source.payload == .surface) {
                    const id = copy.source.payload.surface;
                    const snapshot = try self.surfaces.snapshot(id);
                    defer snapshot.deinit();
                    try copy.area.validate(snapshot.width, snapshot.height);
                    if (try self.surfaces.copySurface(copy.base.surface, id, clips.rectangles.items, copy.base.box, copy.area, token)) |revision| return .{ .frame = revision };
                } else {
                    var pending: ?PendingPalette = null;
                    defer if (pending) |p| self.allocator.free(p.entries);
                    const image = try self.resolve(copy.source, retained, &pending, token);
                    defer image.release();
                    try copy.area.validate(image.width, image.height);
                    if (mutation) |m| _ = try self.world.images.stage(m, image);
                    const revision = try self.surfaces.copyImage(copy.base.surface, clips.rectangles.items, copy.base.box, copy.area, image, token);
                    if (pending) |p| {
                        if (self.palettes.get(p.id)) |old| self.allocator.free(old);
                        self.palettes.putAssumeCapacity(p.id, p.entries);
                        pending = null;
                    }
                    if (mutation) |m| _ = self.world.images.commit(m);
                    if (revision) |value| return .{ .frame = value };
                }
            },
            .unknown => |message| {
                switch (message) {
                    122...126, 316...318 => return error.VideoOrMonitorMigrationPending,
                    else => {},
                }
            },
        }
        return .{ .ignored = kind };
    }
    fn makeRegion(self: *State, base: protocol.Base) !region.Region {
        const snapshot = try self.surfaces.snapshot(base.surface);
        defer snapshot.deinit();
        return region.Region.init(self.allocator, base.box, .{ .x = 0, .y = 0, .width = @intCast(snapshot.width), .height = @intCast(snapshot.height) }, base.clips, .{});
    }
    const PendingPalette = struct { id: u64, entries: []u32 };
    fn fromLZ(decoded: lz.Image) !Image {
        errdefer decoded.deinit();
        return Image.adopt(decoded.allocator, decoded.width, decoded.height, decoded.top_down, if (decoded.has_alpha) .straight else .opaque_pixels, decoded.pixels);
    }
    fn resolve(self: *State, source: protocol.Image, retained: usize, pending: *?PendingPalette, token: *cancel.Token) !Image {
        const d = source.descriptor;
        switch (source.payload) {
            .surface => return error.InvalidState,
            .cached => |lossless| {
                const image = try self.world.images.resolve(d.id, if (lossless) .lossless else .any, retained, token);
                errdefer image.release();
                if (image.width != d.width or image.height != d.height) return error.DimensionMismatch;
                return image;
            },
            .glz => |data| return self.world.dictionary.decode(data, d.width, d.height, retained, token),
            .zlib_glz => |data| {
                var inflated: []u8 = undefined;
                {
                    try self.world.executor.acquire(retained, token);
                    defer self.world.executor.finish();
                    inflated = try zlib.inflate(self.allocator, data.data, data.size, .{}, token);
                }
                defer self.allocator.free(inflated);
                return self.world.dictionary.decode(inflated, d.width, d.height, retained, token);
            },
            else => {},
        }
        try self.world.executor.acquire(retained, token);
        defer self.world.executor.finish();
        return switch (source.payload) {
            .raw => |raw| blk: {
                if (raw.format != 8 and raw.format != 9) return error.UnsupportedRAWFormat;
                if (d.width == 0 or d.height == 0 or d.width > 16384 or d.height > 16384 or raw.stride < @as(usize, d.width) * 4 or raw.data.len != try std.math.mul(usize, raw.stride, d.height)) return error.InvalidBitmap;
                const image = try Image.create(self.allocator, d.width, d.height, raw.flags & 4 != 0, if (raw.format == 9) .straight else .opaque_pixels);
                errdefer image.release();
                const output = image.unpublishedPixels();
                for (0..d.height) |y| {
                    try token.check();
                    @memcpy(output[y * image.stride ..][0..image.stride], raw.data[y * raw.stride ..][0..image.stride]);
                }
                break :blk image;
            },
            .jpeg => |data| blk: {
                var decoder = try native.JPEG.init();
                defer decoder.deinit();
                break :blk try decoder.decode(self.allocator, data, d.width, d.height, .{}, token);
            },
            .quic => |data| try native.quic(self.allocator, data, d.width, d.height, .{}, token),
            .lz => |data| try fromLZ(try lz.decode(self.allocator, data, d.width, d.height, null, .{})),
            .lz_palette => |data| blk: {
                const entries = switch (data.palette) {
                    .cached => |id| self.palettes.get(id) orelse return error.MissingPalette,
                    .inline_data => |palette| p: {
                        if (data.flags & 1 != 0) {
                            if (!self.palettes.contains(palette.id) and self.palettes.count() >= 256) return error.PaletteLimit;
                            try self.palettes.ensureUnusedCapacity(self.allocator, 1);
                            pending.* = .{ .id = palette.id, .entries = try self.allocator.dupe(u32, palette.entries) };
                        }
                        break :p palette.entries;
                    },
                };
                break :blk try fromLZ(try lz.decode(self.allocator, data.data, d.width, d.height, entries, .{}));
            },
            else => unreachable,
        };
    }
};
