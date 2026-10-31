//! Capture registry shared by a Source and its native presentation hosts. A
//! capture retains its registry; registry borrows the active capture only while
//! holding its mutex. Detach drains all observers before freezing evidence.
//! Lock order: capture state -> registry -> assembler/waiter. No external
//! callbacks or filesystem I/O under registry/state locks. Destruction joins
//! callers; Source destruction does not invalidate a retained Capture.
const std = @import("std");
const sync = @import("sync.zig");
const trace = @import("interaction_trace.zig");
const record = @import("interaction_record.zig");
const writer = @import("interaction_writer.zig");
const wait = @import("interaction_waiter.zig");
const cancel = @import("cancel.zig");
const desktop = @import("desktop_snapshot.zig");
pub const Registry = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: sync.Mutex = .{},
    active: ?*Capture = null,
    pub fn create(a: std.mem.Allocator) !*Registry {
        const self = try a.create(Registry);
        self.* = .{ .allocator = a };
        return self;
    }
    pub fn retain(self: *Registry) *Registry {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old > 0 and old < std.math.maxInt(usize));
        return self;
    }
    pub fn release(self: *Registry) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        std.debug.assert(self.active == null);
        self.mutex.deinit();
        self.allocator.destroy(self);
    }
    fn install(self: *Registry, capture: *Capture) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active != null) return error.CaptureAlreadyActive;
        self.active = capture;
    }
    fn remove(self: *Registry, capture: *Capture) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active == capture) self.active = null;
    }
    pub fn frame(self: *Registry, snapshot: desktop.Snapshot, received: ?u64, ready: ?u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active) |c| c.assembler.frame(snapshot, received, ready) catch c.assembler.unavailable(.pixels);
    }
    pub fn selected(self: *Registry, id: trace.Identity, ready: u64, ns: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active) |c| c.assembler.select(id, ready, ns);
    }
    pub fn committed(self: *Registry, id: trace.Identity, ns: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active) |c| c.assembler.commit(id, ns);
    }
    pub fn presented(self: *Registry, id: trace.Identity, ns: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Wakes a blocking thread only. It cannot synchronously call user code.
        if (self.active) |c| if (c.assembler.presented(id, ns)) c.waiter.complete(id);
    }
    pub fn dropped(self: *Registry, id: trace.Identity) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active) |c| c.assembler.drop(id);
    }
    pub fn retireDesktop(self: *Registry, generation: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active) |c| c.assembler.retireDesktop(generation);
    }
    pub fn retireSurface(self: *Registry, channel: u8, surface: u32, generation: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active) |c| c.assembler.retireSurface(.{ .channel = channel, .surface = surface }, generation) catch c.assembler.unavailable(.retirement);
    }
};
pub const Capture = struct {
    allocator: std.mem.Allocator,
    registry: *Registry,
    assembler: *trace.Assembler,
    output: writer.Writer,
    waiter: wait.Waiter = .{},
    mutex: sync.Mutex = .{},
    append_mutex: sync.Mutex = .{},
    phase: enum { active, frozen, pending, appended } = .active,
    external: ?[]u8 = null,
    encoded: ?[]u8 = null,
    pub fn create(a: std.mem.Allocator, registry: *Registry, config: trace.Config, path: []const u8) !*Capture {
        const self = try a.create(Capture);
        errdefer a.destroy(self);
        const assembler = try trace.Assembler.create(a, config);
        errdefer assembler.destroy();
        const output = try writer.Writer.init(a, path);
        errdefer output.deinit();
        self.* = .{ .allocator = a, .registry = registry, .assembler = assembler, .output = output };
        try registry.install(self);
        _ = registry.retain();
        return self;
    }
    pub fn destroy(self: *Capture) void {
        self.registry.remove(self);
        self.waiter.finish();
        self.waiter.deinit();
        self.registry.release();
        self.assembler.destroy();
        self.output.deinit();
        if (self.external) |v| self.allocator.free(v);
        if (self.encoded) |v| self.allocator.free(v);
        self.mutex.deinit();
        self.append_mutex.deinit();
        self.allocator.destroy(self);
    }
    fn check(self: *Capture) !void {
        if (self.phase != .active) return error.CaptureAlreadyFinished;
    }
    pub fn hostInput(self: *Capture, scheduled: u64, input: u64, started: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.check();
        self.assembler.hostInput(scheduled, input, started);
    }
    pub fn sendCompleted(self: *Capture, ns: u64, ack: ?u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.check();
        self.assembler.sendCompleted(ns, ack);
    }
    pub fn motionAcknowledged(self: *Capture, ns: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.check();
        self.assembler.motionAcknowledged(ns);
    }
    pub fn guestEvidence(self: *Capture, received: u64, drawn: u64, revision: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.check();
        self.assembler.guestEvidence(received, drawn, revision);
    }
    pub fn waitPresented(self: *Capture, token: *cancel.Token) !trace.Identity {
        self.mutex.lock();
        const active = self.phase == .active;
        self.mutex.unlock();
        if (!active) return error.CaptureAlreadyFinished;
        return self.waiter.wait(token);
    }
    /// Idempotent retry after a write error retains exact frozen evidence. A
    /// second successful finish is an error. Returned JSON is independently owned.
    pub fn finish(self: *Capture, a: std.mem.Allocator, reason: ?[]const u8) ![]u8 {
        self.append_mutex.lock();
        defer self.append_mutex.unlock();
        self.mutex.lock();
        const output = blk: {
            defer self.mutex.unlock();
            if (self.phase == .appended) return error.CaptureAlreadyFinished;
            if (self.phase == .active) {
                if (reason) |text| {
                    if (text.len > record.maximum_record_bytes) return error.RecordTooLarge;
                    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUTF8;
                    self.external = try self.allocator.dupe(u8, text);
                }
                self.registry.remove(self);
                self.phase = .frozen;
                self.waiter.finish();
            }
            if (self.phase == .frozen) {
                self.encoded = try self.assembler.finishEncoded(self.allocator, self.external);
                self.phase = .pending;
            }
            break :blk self.encoded.?;
        };
        // Reserve result ownership before the external effect; allocation
        // failure cannot turn a successful append into an apparent write failure.
        const result = try a.dupe(u8, output);
        errdefer a.free(result);
        try self.output.append(output);
        self.mutex.lock();
        self.phase = .appended;
        self.mutex.unlock();
        return result;
    }
};
