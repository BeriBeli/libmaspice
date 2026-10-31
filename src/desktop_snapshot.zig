//! Immutable aggregate desktop updates. Clones retain CPU/IOSurface leases and
//! cursor payloads without copying pixels. Every returned Snapshot is owned.
const std = @import("std");
const surface = @import("surface.zig");
const cursor = @import("cursor.zig");
const damage = @import("damage.zig");
const sync = @import("sync.zig");
pub const Key = struct { channel: u8 = 0, surface: u32 = 0 };
pub const Revision = struct {
    session: u64 = 0,
    channel: u8,
    surface: surface.Revision,
    pub fn sameSurface(self: Revision, other: Revision) bool {
        return self.session == other.session and self.channel == other.channel and self.surface.id == other.surface.id and self.surface.lifecycle == other.surface.lifecycle;
    }
    pub fn equal(self: Revision, other: Revision) bool {
        return self.sameSurface(other) and self.surface.value == other.surface.value;
    }
};
pub const PointerMode = enum(u8) { absolute, relative };
pub const Frame = struct {
    session: u64 = 0,
    publication: surface.Publication,
    channel: u8,
    damage: damage.Journal,
    sequence: u64 = 0,
    timing: ?@import("frame_publisher.zig").Timing = null,
    pub fn revision(self: Frame) Revision {
        return .{ .session = self.session, .channel = self.channel, .surface = self.publication.snapshot().revision };
    }
    pub fn clone(self: Frame) Frame {
        var result = self;
        result.publication = self.publication.retain();
        return result;
    }
    pub fn deinit(self: Frame) void {
        self.publication.release();
    }
};
pub const Stamp = struct {
    generation: u64,
    sequence: u64,
    pub fn order(self: Stamp, other: Stamp) std.math.Order {
        const generation = std.math.order(self.generation, other.generation);
        return if (generation == .eq) std.math.order(self.sequence, other.sequence) else generation;
    }
};
pub const Snapshot = struct {
    stamp: Stamp,
    frame: ?Frame = null,
    cursor: ?cursor.Snapshot = null,
    pointer: PointerMode = .absolute,
    pub fn clone(self: Snapshot) Snapshot {
        var result = self;
        if (self.frame) |frame| result.frame = frame.clone();
        if (self.cursor) |c| result.cursor = c.clone();
        return result;
    }
    pub fn deinit(self: Snapshot) void {
        if (self.frame) |frame| frame.deinit();
        if (self.cursor) |c| c.deinit();
    }
    /// Borrows both inputs. The result owns a new lease on the newest snapshot.
    /// Different identities/generations force a full redraw; cursor-only updates
    /// keep all accumulated damage and the original frame delivery sequence.
    pub fn merge(previous: Snapshot, incoming: Snapshot) Snapshot {
        const incoming_newest = incoming.stamp.order(previous.stamp) != .lt;
        const newest = if (incoming_newest) incoming else previous;
        const older = if (incoming_newest) previous else incoming;
        var result = newest.clone();
        if (result.frame) |*frame| {
            if (older.stamp.generation != newest.stamp.generation or older.frame == null or !frame.revision().sameSurface(older.frame.?.revision())) {
                frame.damage.markFull();
            } else {
                // A reused identity with different dimensions cannot safely
                // interpret old rectangles; full redraw preserves correctness.
                frame.damage.merge(older.frame.?.damage) catch frame.damage.markFull();
            }
        }
        return result;
    }
};
/// A single pending update plus a persistent watermark. take/discard do not
/// permit old callbacks to resurrect consumed frames. Destroy after callers join.
pub const ReadyLatch = struct {
    mutex: sync.Mutex = .{},
    pending: ?Snapshot = null,
    ready_ns: u64 = 0,
    newest: ?Stamp = null,
    pub const Ready = struct {
        snapshot: Snapshot,
        ready_ns: u64,
        waiting_ns: u64,
        pub fn deinit(self: Ready) void {
            self.snapshot.deinit();
        }
    };
    pub fn deinit(self: *ReadyLatch) void {
        self.discard();
        self.mutex.deinit();
    }
    /// Borrows input and returns true only for the empty-to-ready transition.
    pub fn offer(self: *ReadyLatch, snapshot: Snapshot, ready_ns: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.newest) |stamp| if (snapshot.stamp.order(stamp) != .gt) return false;
        const was_empty = self.pending == null;
        const result = if (self.pending) |old| Snapshot.merge(old, snapshot) else snapshot.clone();
        if (self.pending) |old| old.deinit();
        self.pending = result;
        self.ready_ns = ready_ns;
        self.newest = result.stamp;
        return was_empty;
    }
    pub fn take(self: *ReadyLatch, selected_ns: u64) ?Ready {
        self.mutex.lock();
        defer self.mutex.unlock();
        const pending = self.pending orelse return null;
        self.pending = null;
        return .{ .snapshot = pending, .ready_ns = self.ready_ns, .waiting_ns = selected_ns -| self.ready_ns };
    }
    pub fn restoreIfEmpty(self: *ReadyLatch, snapshot: Snapshot, ready_ns: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending != null) return false;
        if (self.newest) |stamp| if (snapshot.stamp.order(stamp) == .lt) return false;
        self.pending = snapshot.clone();
        self.newest = snapshot.stamp;
        self.ready_ns = ready_ns;
        return true;
    }
    pub fn discard(self: *ReadyLatch) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending) |snapshot| snapshot.deinit();
        self.pending = null;
    }
    pub fn isEmpty(self: *ReadyLatch) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pending == null;
    }
};
