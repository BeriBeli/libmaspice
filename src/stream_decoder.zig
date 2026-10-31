//! Stream decode/presentation contract. A scheduler serializes render per stream
//! and snapshots clips on admission. Decode permits and native frames are held
//! only as long as needed; reference-coded input is decoded even when late.
const std = @import("std");
const wire = @import("bytes.zig");
const protocol = @import("stream_wire.zig");
const surface = @import("surface.zig");
const region = @import("region.zig");
const native = @import("native_codecs.zig");
const video = @import("video.zig");
const graphics = @import("graphics.zig");
const cancel = @import("cancel.zig");
const clock = @import("clock.zig");
const executor = @import("codec_executor.zig");
const Image = @import("image.zig").Image;
pub const Job = struct {
    payload: wire.Slice,
    time: u32,
    width: usize,
    height: usize,
    source: region.Rect,
    destination: region.Rect,
    clips: region.Region,
    admission: surface.Store.VideoAdmission,
    pub fn deinit(self: *Job) void {
        self.payload.release();
        self.clips.deinit();
    }
    pub fn weight(self: Job) usize {
        return self.payload.retainedBytes() + self.clips.rectangles.capacity * @sizeOf(region.Rect);
    }
};
pub const Stats = struct { decoded: usize = 0, dropped_before_decode: usize = 0, dropped_after_decode: usize = 0, presented: usize = 0, cpu_fallback: usize = 0 };
pub const Metrics = struct {
    video_sessions: u64 = 0,
    video_hardware: u64 = 0,
    video_software: u64 = 0,
    video_query_failures: u64 = 0,
    video_decoded: u64 = 0,
    video_dropped: u64 = 0,
    video_materializations: u64 = 0,
    mjpeg_handles: u64 = 0,
    mjpeg_decoded: u64 = 0,
    mjpeg_native: u64 = 0,
    mjpeg_data_fallbacks: u64 = 0,
    mjpeg_allocations: u64 = 0,
    mjpeg_late: u64 = 0,
    mjpeg_superseded: u64 = 0,
    mjpeg_peak_buffers: usize = 0,
    mjpeg_peak_decodes: usize = 0,
    advanced_cpu_fallbacks: u64 = 0,
    native_fallbacks: u64 = 0,
    native_disables: u64 = 0,
    first_disable_reason: ?anyerror = null,
    pub fn accumulate(self: *Metrics, other: Metrics) void {
        inline for (comptime std.meta.fieldNames(Metrics)) |f| {
            if (comptime std.mem.startsWith(u8, f, "mjpeg_peak_")) @field(self, f) = @max(@field(self, f), @field(other, f)) else if (@FieldType(Metrics, f) == u64) @field(self, f) +|= @field(other, f) else if (self.first_disable_reason == null) self.first_disable_reason = other.first_disable_reason;
        }
    }
    pub fn delta(self: Metrics, previous: Metrics) Metrics {
        var result = self;
        inline for (comptime std.meta.fieldNames(Metrics)) |f| {
            if (@FieldType(Metrics, f) == u64 and comptime !std.mem.startsWith(u8, f, "mjpeg_peak_")) @field(result, f) -|= @field(previous, f);
        }
        if (previous.first_disable_reason != null) result.first_disable_reason = null;
        return result;
    }
};
/// Scheduler owns this until all renders join. Direct Stream callers can omit
/// it; only decoder work after acquiring a permit contributes concurrency.
pub const Activity = struct {
    mutex: @import("sync.zig").Mutex = .{},
    decodes: usize = 0,
    buffers: usize = 0,
    peak_decodes: usize = 0,
    peak_buffers: usize = 0,
    pub fn begin(self: *Activity, comptime buffer: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (buffer) {
            self.buffers += 1;
            self.peak_buffers = @max(self.peak_buffers, self.buffers);
        } else {
            self.decodes += 1;
            self.peak_decodes = @max(self.peak_decodes, self.decodes);
        }
    }
    pub fn end(self: *Activity, comptime buffer: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (buffer) {
            std.debug.assert(self.buffers > 0);
            self.buffers -= 1;
        } else {
            std.debug.assert(self.decodes > 0);
            self.decodes -= 1;
        }
    }
    pub fn sample(self: *Activity, metrics_value: *Metrics) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        metrics_value.mjpeg_peak_decodes = self.peak_decodes;
        metrics_value.mjpeg_peak_buffers = self.peak_buffers;
    }
    pub fn deinit(self: *Activity) void {
        std.debug.assert(self.decodes == 0 and self.buffers == 0);
        self.mutex.deinit();
    }
};
pub const Stream = struct {
    allocator: std.mem.Allocator,
    config: protocol.Create, // clips cleared; snapshots supplied to prepare.
    lifecycle: u64,
    backend: union(enum) { jpeg: native.JPEG, advanced: video.Decoder },
    native_disabled: bool = false,
    stats: Stats = .{},
    counts: Metrics = .{},
    activity: ?*Activity = null,
    pub fn init(a: std.mem.Allocator, store: *surface.Store, config: protocol.Create) !Stream {
        if (config.id >= 64) return error.InvalidStreamID;
        if (config.width == 0 or config.height == 0 or config.source_width == 0 or config.source_height == 0 or config.source_width > config.width or config.source_height > config.height or config.width > 16384 or config.height > 16384) return error.InvalidDimensions;
        const snapshot = try store.snapshot(config.surface);
        defer snapshot.deinit();
        try config.destination.validate(snapshot.width, snapshot.height);
        var clips = try region.Region.init(a, config.destination, .{ .x = 0, .y = 0, .width = @intCast(snapshot.width), .height = @intCast(snapshot.height) }, config.clips, .{});
        defer clips.deinit();
        var owned = config;
        owned.clips = null;
        return .{ .allocator = a, .config = owned, .lifecycle = snapshot.revision.lifecycle, .backend = switch (config.codec) {
            .mjpeg => .{ .jpeg = try native.JPEG.init() },
            .h264, .h265 => .{ .advanced = try video.Decoder.init(a, if (config.codec == .h264) .h264 else .h265, config.width, config.height, .{}) },
            else => return error.UnsupportedVideoCodec,
        } };
    }
    /// Only the serialized render owner reads this; Scheduler publishes a copy
    /// under its own mutex after each completed (including failed) render.
    pub fn metrics(self: *const Stream) Metrics {
        var result = self.counts;
        switch (self.backend) {
            .jpeg => {
                result.mjpeg_handles = 1;
                result.mjpeg_decoded = self.stats.decoded;
                result.mjpeg_late = self.stats.dropped_before_decode;
            },
            .advanced => |decoder| {
                result.video_sessions = decoder.stats.sessions;
                result.video_hardware = decoder.stats.hardware;
                result.video_software = decoder.stats.software;
                result.video_query_failures = decoder.stats.query_failed;
                result.video_decoded = decoder.stats.frames;
                result.video_dropped = decoder.stats.dropped;
                result.advanced_cpu_fallbacks = self.stats.cpu_fallback;
            },
        }
        return result;
    }
    pub fn videoFailure(self: *const Stream, failure: anyerror) ?@import("video_failure.zig").Failure {
        return switch (self.backend) {
            .jpeg => null,
            .advanced => |decoder| @import("video_failure.zig").classify(decoder.codec, failure, decoder.last_status),
        };
    }
    pub fn deinit(self: *Stream) void {
        switch (self.backend) {
            .jpeg => |*d| d.deinit(),
            .advanced => |*d| d.deinit(),
        }
    }
    pub fn prepare(self: *Stream, store: *surface.Store, payload: wire.Slice, time: u32, sizing: ?protocol.Sizing, clips: ?[]const region.Rect) !Job {
        if (payload.bytes().len == 0 or payload.bytes().len > 64 * 1024 * 1024) return error.InvalidEncodedSize;
        const admission = try store.admitVideo(self.config.surface);
        if (admission.barrier.lifecycle != self.lifecycle) return error.StaleSurface;
        const width = if (sizing) |v| v.width else self.config.width;
        const height = if (sizing) |v| v.height else self.config.height;
        if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.InvalidDimensions;
        if (@as(u64, width) * height * 4 > 256 * 1024 * 1024) return error.DecodedImageTooLarge;
        const destination = if (sizing) |v| v.destination else self.config.destination;
        try destination.validate(admission.width, admission.height);
        const source_width = if (sizing != null) width else self.config.source_width;
        const source_height = if (sizing != null) height else self.config.source_height;
        const area = try region.Region.init(self.allocator, destination, .{ .x = 0, .y = 0, .width = @intCast(admission.width), .height = @intCast(admission.height) }, clips, .{});
        return .{ .payload = payload.clone(), .time = time, .width = width, .height = height, .source = .{ .x = 0, .y = if (self.config.top_down) 0 else height - source_height, .width = source_width, .height = source_height }, .destination = destination, .clips = area, .admission = admission };
    }
    const Decoded = union(enum) {
        cpu: Image,
        jpeg: *graphics.Frame,
        advanced: video.Frame,
        fn deinit(self: Decoded) void {
            switch (self) {
                .cpu => |i| i.release(),
                .jpeg => |f| f.release(),
                .advanced => |f| f.deinit(),
            }
        }
    };
    fn decode(self: *Stream, job: Job, store: *surface.Store, pool: *executor.Executor, token: *cancel.Token) !?Decoded {
        try pool.acquire(job.payload.retainedBytes(), token);
        defer pool.finish();
        switch (self.backend) {
            .advanced => |*decoder| {
                // Decoder contract keeps the stream's configured dimensions.
                // Sized messages are still checked against the returned frame.
                const frame = (try decoder.decode(job.payload.bytes(), job.time, token)) orelse return null;
                if (frame.width != job.width or frame.height != job.height) {
                    frame.deinit();
                    return error.DimensionMismatch;
                }
                return .{ .advanced = frame };
            },
            .jpeg => |*decoder| {
                if (self.activity) |activity| activity.begin(false);
                defer if (self.activity) |activity| activity.end(false);
                if (store.graphics) |context| {
                    const frame = context.create(self.allocator, job.width, job.height) catch |err| switch (err) {
                        error.NativeBudgetExceeded, error.NativePoolExhausted, error.NativeAllocationFailed, error.OutOfMemory => null,
                        else => return err,
                    };
                    if (frame) |output| {
                        self.counts.mjpeg_allocations +|= 1;
                        if (self.activity) |activity| activity.begin(true);
                        errdefer if (self.activity) |activity| activity.end(true);
                        errdefer output.release();
                        const mapping = try output.lock(true);
                        var locked = true;
                        defer if (locked) mapping.unlock() catch {};
                        try decoder.into(job.payload.bytes(), job.width, job.height, mapping.bytes, mapping.stride, .{}, token);
                        try mapping.unlock();
                        locked = false;
                        self.counts.mjpeg_native +|= 1;
                        return .{ .jpeg = output };
                    }
                }
                const image = try decoder.decode(self.allocator, job.payload.bytes(), job.width, job.height, .{}, token);
                self.counts.mjpeg_data_fallbacks +|= 1;
                return .{ .cpu = image };
            },
        }
    }
    const ClockWait = struct {
        media: *clock.Clock,
        token: clock.Token = .{},
        fn wake(p: *anyopaque) void {
            const self: *ClockWait = @ptrCast(@alignCast(p));
            self.media.cancelWait(&self.token);
        }
    };
    fn fallback(err: anyerror) bool {
        return switch (err) {
            error.MetalUnavailable, error.GPUFailed, error.UnsupportedPixelFormat, error.UnsupportedPlaneGeometry, error.UnsupportedColorMatrix, error.UnsupportedColorRange, error.NativePoolExhausted, error.NativeBudgetExceeded, error.NativeAllocationFailed => true,
            else => false,
        };
    }
    fn nativeResult(self: *Stream, store: *surface.Store, source: anytype, job: Job, token: *cancel.Token) !?surface.Revision {
        return store.drawNativeVideo(self.config.surface, source, job.source, job.destination, job.clips.rectangles.items, !self.config.top_down, job.admission.barrier, job.admission.sequence, token);
    }
    pub fn render(self: *Stream, job: Job, store: *surface.Store, pool: *executor.Executor, media: ?*clock.Clock, token: *cancel.Token) !?surface.Revision {
        try token.check();
        const late = if (media) |c| clock.margin(c.current(), job.time) < 0 else false;
        if (late and self.config.codec == .mjpeg) {
            self.stats.dropped_before_decode += 1;
            return null;
        }
        const decoded = (try self.decode(job, store, pool, token)) orelse return null;
        defer decoded.deinit();
        defer if (decoded == .jpeg) {
            if (self.activity) |activity| activity.end(true);
        };
        self.stats.decoded += 1;
        if (late) {
            self.stats.dropped_after_decode += 1;
            return null;
        }
        if (media) |c| {
            var wait: ClockWait = .{ .media = c };
            var registration: cancel.Registration = .{ .context = &wait, .wake = ClockWait.wake };
            token.register(&registration);
            defer token.unregister(&registration);
            const margin = try c.wait(job.time, &wait.token);
            if (margin < 0 and self.config.codec != .mjpeg) {
                self.stats.dropped_after_decode += 1;
                return null;
            }
        }
        try token.check();
        if (job.clips.rectangles.items.len == 0) return null;
        var revision: ?surface.Revision = null;
        var used_native = false;
        if (!self.native_disabled and decoded != .cpu) {
            const result: anyerror!?surface.Revision = switch (decoded) {
                .jpeg => |f| self.nativeResult(store, f, job, token),
                .advanced => |f| self.nativeResult(store, f, job, token),
                .cpu => error.MetalUnavailable,
            };
            if (result) |value| {
                revision = value;
                used_native = true;
            } else |err| {
                if (!fallback(err)) return err;
                self.counts.native_fallbacks +|= 1;
                if (err == error.MetalUnavailable or err == error.GPUFailed) {
                    self.native_disabled = true;
                    self.counts.native_disables +|= 1;
                    if (self.counts.first_disable_reason == null) self.counts.first_disable_reason = err;
                }
            }
        }
        if (!used_native) {
            self.stats.cpu_fallback += 1;
            const image = try switch (decoded) {
                .cpu => |i| @as(anyerror!Image, i.retain()),
                .advanced => |f| blk: {
                    const result = try f.copyBGRA(self.allocator, token);
                    self.counts.video_materializations +|= 1;
                    break :blk result;
                },
                .jpeg => |f| blk: {
                    const output = try Image.create(self.allocator, f.width, f.height, true, .opaque_pixels);
                    errdefer output.release();
                    const mapping = try f.lock(false);
                    var locked = true;
                    defer if (locked) mapping.unlock() catch {};
                    for (0..f.height) |y| {
                        @memcpy(output.unpublishedPixels()[y * output.stride ..][0..output.stride], mapping.bytes[y * mapping.stride ..][0..output.stride]);
                    }
                    try mapping.unlock();
                    locked = false;
                    break :blk output;
                },
            };
            defer image.release();
            revision = try store.drawScaledVideo(self.config.surface, image, self.config.codec != .mjpeg, job.source, job.destination, job.clips.rectangles.items, !self.config.top_down, job.admission.barrier, job.admission.sequence, token);
        }
        if (revision != null) self.stats.presented += 1;
        return revision;
    }
};
