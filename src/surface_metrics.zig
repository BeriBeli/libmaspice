//! Content-free Surface evidence. Recorder lifetime is independent of Store:
//! retained publications may materialize pixels after channel destruction.
const std = @import("std");
const sync = @import("sync.zig");
pub const Metrics = struct {
    damage_operations: u64 = 0,
    damage_bytes: u64 = 0,
    snapshots: u64 = 0,
    full_copy_bytes: u64 = 0,
    partial_copy_bytes: u64 = 0,
    direct_native_write_bytes: u64 = 0,
    cpu_materializations: u64 = 0,
    cpu_materialization_bytes: u64 = 0,
    pool_exhaustions: u64 = 0,
    gpu_copy_bytes: u64 = 0,
    gpu_errors: u64 = 0,
    native_video_frames: u64 = 0,
    // Samples, not counters. Session accumulation retains their maximum.
    publications: usize = 0,
    pool_in_use: usize = 0,
    allocated_frames: usize = 0,
    allocated_bytes: usize = 0,
    native_enabled: bool = false,
    recommended_working_set: u64 = 0,
    metal_allocated_bytes: u64 = 0,
    pub fn accumulate(self: *Metrics, other: Metrics) void {
        inline for (comptime std.meta.fieldNames(Metrics)) |f| {
            if (@FieldType(Metrics, f) == bool) @field(self, f) = @field(self, f) or @field(other, f) else if (comptime std.mem.eql(u8, f, "publications") or std.mem.eql(u8, f, "pool_in_use") or std.mem.eql(u8, f, "allocated_frames") or std.mem.eql(u8, f, "allocated_bytes") or std.mem.eql(u8, f, "recommended_working_set") or std.mem.eql(u8, f, "metal_allocated_bytes")) @field(self, f) = @max(@field(self, f), @field(other, f)) else @field(self, f) +|= @field(other, f);
        }
    }
};
pub const Recorder = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: sync.Mutex = .{},
    value: Metrics = .{},
    pub fn create(a: std.mem.Allocator) !*Recorder {
        const self = try a.create(Recorder);
        self.* = .{ .allocator = a };
        return self;
    }
    pub fn retain(self: *Recorder) *Recorder {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old > 0 and old < std.math.maxInt(usize));
        return self;
    }
    pub fn release(self: *Recorder) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            self.mutex.deinit();
            self.allocator.destroy(self);
        }
    }
    pub fn add(self: *Recorder, comptime field: []const u8, value: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        @field(self.value, field) +|= value;
    }
    pub fn materialized(self: *Recorder, bytes: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.value.cpu_materializations +|= 1;
        self.value.cpu_materialization_bytes +|= bytes;
    }
    pub fn publicationReleased(self: *Recorder) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.value.publications > 0);
        self.value.publications -= 1;
    }
    pub fn snapshot(self: *Recorder) Metrics {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.value;
    }
};
