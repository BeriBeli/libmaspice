//! Bounded causal trace assembler. Configuration is owned; frames retain only
//! identities/timestamps/marker metadata, never pixels. At most 16 observations
//! and 4096 retired surface keys are retained per capture. Stable address; join
//! users before destroy. Callbacks/waiter wakeups happen in the owning registry.
const std = @import("std");
const sync = @import("sync.zig");
const record = @import("interaction_record.zig");
const marker = @import("interaction_marker.zig");
const desktop = @import("desktop_snapshot.zig");
pub const Identity = struct {
    desktop_generation: u64,
    channel: u8,
    surface: u32,
    surface_generation: u64,
    revision: u64,
    sequence: u64,
    pub fn equal(self: Identity, other: Identity) bool {
        return std.meta.eql(self, other);
    }
    pub fn from(snapshot: desktop.Snapshot) ?Identity {
        const frame = snapshot.frame orelse return null;
        const revision = frame.revision();
        return .{ .desktop_generation = snapshot.stamp.generation, .channel = frame.channel, .surface = revision.surface.id, .surface_generation = revision.surface.lifecycle, .revision = revision.surface.value, .sequence = frame.sequence };
    }
};
pub const Config = struct { pair_id: []const u8, version: []const u8, run_id: []const u8, order: u64, action: record.Action, token: []const u8, checksum: u32 };
pub const Observation = struct { identity: Identity, payload: ?marker.Payload, received_ns: ?u64, ready_ns: ?u64 };
const Key = struct { channel: u8, surface: u32 };
fn same(a: ?Identity, b: Identity) bool {
    return if (a) |value| value.equal(b) else false;
}
pub const Assembler = struct {
    allocator: std.mem.Allocator,
    config: Config,
    config_bytes: []u8,
    mutex: sync.Mutex = .{},
    scheduled: ?u64 = null,
    input: ?u64 = null,
    send_started: ?u64 = null,
    send_completed: ?u64 = null,
    motion_ack: ?u64 = null,
    guest_received: ?u64 = null,
    guest_drawn: ?u64 = null,
    guest_revision: ?u64 = null,
    frames: [16]Observation = undefined,
    frame_count: usize = 0,
    selected: ?Identity = null,
    selected_frame: ?Observation = null,
    selected_ready: ?u64 = null,
    selection: ?u64 = null,
    committed: ?Identity = null,
    commit_ns: ?u64 = null,
    dropped: ?Identity = null,
    presented_ns: ?u64 = null,
    replacement: bool = false,
    invalid: ?[]const u8 = null,
    ambiguous_reason: [64]u8 = undefined,
    retired_generation: ?u64 = null,
    retired_surfaces: std.AutoHashMapUnmanaged(Key, u64) = .empty,
    pub fn create(a: std.mem.Allocator, config: Config) !*Assembler {
        var length: usize = 0;
        for ([_][]const u8{ config.pair_id, config.version, config.run_id, config.token }) |value| {
            if (value.len > record.maximum_record_bytes - length) return error.RecordTooLarge;
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUTF8;
            length += value.len;
        }
        const self = try a.create(Assembler);
        errdefer a.destroy(self);
        const bytes = try a.alloc(u8, length);
        self.* = .{ .allocator = a, .config = config, .config_bytes = bytes };
        var offset: usize = 0;
        inline for (.{ "pair_id", "version", "run_id", "token" }) |name| {
            const value = @field(config, name);
            @memcpy(bytes[offset..][0..value.len], value);
            @field(self.config, name) = bytes[offset..][0..value.len];
            offset += value.len;
        }
        return self;
    }
    pub fn destroy(self: *Assembler) void {
        self.retired_surfaces.deinit(self.allocator);
        self.mutex.deinit();
        self.allocator.free(self.config_bytes);
        self.allocator.destroy(self);
    }
    pub fn unavailable(self: *Assembler, kind: enum { pixels, retirement }) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.fail(switch (kind) {
            .pixels => "frame_pixels_unavailable",
            .retirement => "trace_retirement_failed",
        });
    }
    fn fail(self: *Assembler, reason: []const u8) void {
        if (self.invalid == null) self.invalid = reason;
    }
    pub fn hostInput(self: *Assembler, scheduled: u64, input: u64, started: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.input != null) {
            self.fail("duplicate_host_evidence");
            return;
        }
        self.scheduled = scheduled;
        self.input = input;
        self.send_started = started;
    }
    pub fn sendCompleted(self: *Assembler, ns: u64, ack: ?u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.input == null or self.send_started == null) {
            self.fail("send_completion_before_host_evidence");
            return;
        }
        if (self.send_completed != null) {
            self.fail("duplicate_send_completion");
            return;
        }
        self.send_completed = ns;
        if (ack) |value| {
            if (self.motion_ack != null and self.motion_ack.? != value) self.fail("duplicate_motion_ack") else self.motion_ack = value;
        }
    }
    pub fn motionAcknowledged(self: *Assembler, ns: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.motion_ack != null) {
            self.fail("duplicate_motion_ack");
            return;
        }
        self.motion_ack = ns;
    }
    pub fn guestEvidence(self: *Assembler, received: u64, drawn: u64, revision: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.guest_received != null) {
            self.fail("duplicate_guest_evidence");
            return;
        }
        self.guest_received = received;
        self.guest_drawn = drawn;
        self.guest_revision = revision;
    }
    fn eligible(self: *Assembler, received: ?u64) bool {
        if (self.input == null or self.presented_ns != null or self.send_started == null) return false;
        return received == null or received.? >= self.send_started.?;
    }
    /// Borrow immutable snapshot through return. Map native pixels read-only,
    /// scan outside the assembler lock, then recheck presentation/retirement.
    pub fn frame(self: *Assembler, snapshot: desktop.Snapshot, received: ?u64, ready: ?u64) !void {
        const identity = Identity.from(snapshot) orelse return;
        self.mutex.lock();
        const accept = self.eligible(received);
        self.mutex.unlock();
        if (!accept) return;
        const surface = snapshot.frame.?.publication.snapshot();
        const read = try surface.backing.read();
        const detection = marker.detect(read.bytes, surface.width, surface.height, read.stride, self.config.token, self.config.checksum);
        try read.finish();
        self.observe(identity, received, ready, detection);
    }
    pub fn observe(self: *Assembler, identity: Identity, received: ?u64, ready: ?u64, detection: marker.Detection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.eligible(received)) return;
        if (self.retired_generation) |generation| if (identity.desktop_generation <= generation) {
            self.fail("retired_generation_frame");
            return;
        };
        if (self.retiredSurface(identity)) {
            self.fail("surface_lifecycle_retired");
            return;
        }
        for (self.frames[0..self.frame_count]) |f| if (f.identity.equal(identity)) {
            self.fail("duplicate_frame_identity");
            return;
        };
        if (self.frame_count == self.frames.len) {
            self.fail("too_many_observed_frames");
            return;
        }
        var observation: Observation = .{ .identity = identity, .payload = null, .received_ns = received, .ready_ns = ready };
        switch (detection) {
            .none => {},
            .exact => |payload| observation.payload = payload,
            .ambiguous => |count| if (self.invalid == null) {
                self.invalid = std.fmt.bufPrint(&self.ambiguous_reason, "ambiguous_marker_roi_{d}", .{count}) catch unreachable;
            },
        }
        self.frames[self.frame_count] = observation;
        self.frame_count += 1;
    }
    fn hasMarker(self: *Assembler) bool {
        for (self.frames[0..self.frame_count]) |f| if (f.payload != null) return true;
        return false;
    }
    fn selectedMarker(self: *Assembler) ?marker.Payload {
        return if (self.selected_frame) |f| f.payload else null;
    }
    fn clearCommit(self: *Assembler) void {
        self.committed = null;
        self.commit_ns = null;
        self.dropped = null;
    }
    pub fn select(self: *Assembler, identity: Identity, ready: u64, ns: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const previous = self.selected;
        const had_marker = self.selectedMarker() != null;
        if (self.presented_ns != null) {
            if (same(previous, identity)) self.fail("duplicate_selection_after_presented");
            return;
        }
        if (self.commit_ns != null and same(previous, identity)) {
            if (same(self.dropped, identity) or !had_marker) self.clearCommit() else {
                self.fail("duplicate_selection_after_commit");
                return;
            }
        }
        if (previous != null and !same(previous, identity)) self.clearCommit();
        self.selected = identity;
        self.selected_ready = ready;
        self.selection = ns;
        self.selected_frame = null;
        if (self.retired_generation) |generation| if (identity.desktop_generation <= generation) {
            self.fail("retired_generation_selection");
            return;
        };
        if (self.retiredSurface(identity)) {
            self.fail("surface_lifecycle_retired");
            return;
        }
        for (self.frames[0..self.frame_count]) |f| if (f.identity.equal(identity)) {
            self.selected_frame = f;
            break;
        };
        if (self.selectedMarker() == null and (had_marker or self.hasMarker())) self.replacement = true;
    }
    pub fn commit(self: *Assembler, identity: Identity, ns: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!same(self.selected, identity)) return;
        if (same(self.committed, identity)) {
            self.fail("duplicate_metal_commit");
            return;
        }
        if (self.retired_generation) |generation| if (identity.desktop_generation <= generation) {
            self.fail("commit_after_generation_retired");
            return;
        };
        if (self.retiredSurface(identity)) {
            self.fail("surface_lifecycle_retired");
            return;
        }
        self.committed = identity;
        self.commit_ns = ns;
    }
    /// True accepts this exact drawable presentation. Caller may wake its waiter
    /// after this method returns; GPU completion alone must not call presented.
    pub fn presented(self: *Assembler, identity: Identity, ns: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!same(self.selected, identity)) return false;
        const payload = self.selectedMarker() orelse return false;
        if (!record.lowerHex(self.config.token, 16) or payload.token != (std.fmt.parseInt(u64, self.config.token, 16) catch return false) or payload.checksum != self.config.checksum) return false;
        if (self.presented_ns != null) {
            self.fail("duplicate_presented");
            return false;
        }
        if (!same(self.committed, identity) or self.commit_ns == null) {
            self.fail("presented_before_commit");
            return false;
        }
        if (self.retired_generation) |generation| if (identity.desktop_generation <= generation) {
            self.fail("presented_after_generation_retired");
            return false;
        };
        if (self.retiredSurface(identity)) {
            self.fail("surface_lifecycle_retired");
            return false;
        }
        self.presented_ns = ns;
        self.dropped = null;
        self.replacement = false;
        return true;
    }
    pub fn drop(self: *Assembler, identity: Identity) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.presented_ns == null and same(self.selected, identity) and same(self.committed, identity) and self.commit_ns != null) self.dropped = identity;
    }
    fn retiredSurface(self: *Assembler, identity: Identity) bool {
        const generation = self.retired_surfaces.get(.{ .channel = identity.channel, .surface = identity.surface }) orelse return false;
        return identity.surface_generation <= generation;
    }
    pub fn retireSurface(self: *Assembler, key: Key, generation: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.retired_surfaces.contains(key) and self.retired_surfaces.count() >= 4096) return error.TraceSurfaceLimit;
        const entry = try self.retired_surfaces.getOrPut(self.allocator, key);
        entry.value_ptr.* = @max(if (entry.found_existing) entry.value_ptr.* else 0, generation);
        if (self.selected) |id| if (id.channel == key.channel and id.surface == key.surface and id.surface_generation <= generation and self.presented_ns == null) self.fail("surface_lifecycle_retired");
        var kept: usize = 0;
        for (self.frames[0..self.frame_count]) |f| {
            if (f.identity.channel == key.channel and f.identity.surface == key.surface and f.identity.surface_generation <= generation) {
                if (f.payload != null and self.presented_ns == null) self.fail("surface_lifecycle_retired");
            } else {
                self.frames[kept] = f;
                kept += 1;
            }
        }
        self.frame_count = kept;
    }
    pub fn retireDesktop(self: *Assembler, generation: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.retired_generation = @max(self.retired_generation orelse generation, generation);
        var kept: usize = 0;
        for (self.frames[0..self.frame_count]) |f| {
            if (f.identity.desktop_generation <= generation) {
                if (f.payload != null and self.presented_ns == null) self.fail("desktop_generation_retired");
            } else {
                self.frames[kept] = f;
                kept += 1;
            }
        }
        self.frame_count = kept;
    }
    /// Snapshot immutable evidence into owned canonical JSON. Does not close the
    /// assembler; the capture registry detaches it before freezing its final line.
    pub fn finishEncoded(self: *Assembler, a: std.mem.Allocator, external: ?[]const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const payload = self.selectedMarker();
        if (self.guest_revision) |revision| if (payload) |p| if (revision != p.revision) self.fail("guest_marker_revision_mismatch");
        var checksum: [8]u8 = undefined;
        if (payload) |p| _ = std.fmt.bufPrint(&checksum, "{x:0>8}", .{p.checksum}) catch unreachable;
        const id = self.selected;
        const result: record.Record = .{
            .pair_id = self.config.pair_id,
            .version = self.config.version,
            .run_id = self.config.run_id,
            .order = self.config.order,
            .action_class = self.config.action,
            .token = self.config.token,
            .scheduled_ns = self.scheduled,
            .host_input_ns = self.input,
            .send_started_ns = self.send_started,
            .send_completed_ns = self.send_completed,
            .motion_ack_ns = self.motion_ack,
            .guest_received_ns = self.guest_received,
            .guest_marker_drawn_ns = self.guest_drawn,
            .display_receive_ns = if (self.selected_frame) |f| f.received_ns else null,
            .surface_ready_ns = if (self.selected_frame) |f| f.ready_ns else null,
            .selected_revision_ready_ns = self.selected_ready,
            .selection_ns = self.selection,
            .metal_commit_ns = self.commit_ns,
            .presented_ns = self.presented_ns,
            .display_channel_id = if (id) |v| v.channel else null,
            .surface_id = if (id) |v| v.surface else null,
            .surface_generation = if (id) |v| v.surface_generation else null,
            .desktop_generation = if (id) |v| v.desktop_generation else null,
            .frame_revision = if (id) |v| v.revision else null,
            .delivery_sequence = if (id) |v| v.sequence else null,
            .marker_revision = if (payload) |p| p.revision else self.guest_revision,
            .marker_checksum = if (payload != null) &checksum else null,
            .invalid_reason = external orelse self.invalid orelse if (self.replacement) "marker_replaced_before_presented" else if (self.input == null) "missing_input_event" else null,
        };
        return result.encode(a);
    }
};
