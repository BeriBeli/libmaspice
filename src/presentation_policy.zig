//! Platform-independent desktop selection/recovery policy. The UI owner
//! serializes these value types; ReadyLatch provides its own cross-thread lock.
const std = @import("std");
const desktop = @import("desktop_snapshot.zig");
const cursor = @import("cursor.zig");
pub const Revision = desktop.Revision;
fn equal(a: ?Revision, b: Revision) bool {
    return if (a) |v| v.equal(b) else false;
}
pub fn needsFramebuffer(selected: ?Revision, update: Revision, redraw: bool) bool {
    return redraw or !equal(selected, update);
}
pub const Size = struct {
    width: f64 = 0,
    height: f64 = 0,
    fn valid(self: Size) bool {
        return std.math.isFinite(self.width) and std.math.isFinite(self.height) and self.width > 0 and self.height > 0;
    }
};
pub fn drawableSize(view: Size, scale: f64) Size {
    if (!view.valid() or !std.math.isFinite(scale) or scale <= 0) return .{};
    const result: Size = .{ .width = @round(view.width * scale), .height = @round(view.height * scale) };
    return if (std.math.isFinite(result.width) and std.math.isFinite(result.height)) result else .{};
}
pub const CursorLayer = enum { native, overlay };
pub fn cursorLayer(pointer: desktop.PointerMode, captured: bool) CursorLayer {
    return if (pointer == .relative and captured) .overlay else .native;
}
pub const CursorDescriptor = union(enum) { arrow, transparent, image: struct { scale_x: f64, scale_y: f64 } };
/// Descriptor borrows the separately retained Snapshot cursor image. No pixel
/// conversion or UI framework object allocation happens in this policy.
pub fn systemCursor(pointer: desktop.PointerMode, state: ?cursor.Snapshot, frame: ?Size, destination: Size, captured: bool) CursorDescriptor {
    if (pointer == .relative) return if (captured) .transparent else .arrow;
    const current = state orelse return .arrow;
    if (!current.visible) return .transparent;
    const size = frame orelse return .arrow;
    if (!size.valid() or !destination.valid()) return .arrow;
    const payload = current.payload orelse return .arrow;
    const h = payload.header;
    if (h.kind != 0 or h.width == 0 or h.height == 0 or payload.data.bytes().len != @as(usize, h.width) * h.height * 4) return .arrow;
    return .{ .image = .{ .scale_x = destination.width / size.width, .scale_y = destination.height / size.height } };
}
pub const Pacing = struct {
    active: bool = false,
    pub const Action = enum { select_immediately, wait_display_link, select_on_display_link, pause_display_link };
    pub fn ready(self: *Pacing) Action {
        if (self.active) return .wait_display_link;
        self.active = true;
        return .select_immediately;
    }
    pub fn tick(self: *Pacing, has_ready: bool) Action {
        if (self.active and has_ready) return .select_on_display_link;
        self.active = false;
        return .pause_display_link;
    }
    pub fn reset(self: *Pacing) void {
        self.active = false;
    }
};
pub const MetalRecovery = struct {
    allocator: std.mem.Allocator,
    next_id: u64 = 0,
    tracked: ?Revision = null,
    active: std.ArrayList(u64) = .empty,
    failures: u8 = 0,
    maximum_attempts: usize = 64,
    pub const Attempt = struct { revision: Revision, id: u64 };
    pub const Action = enum { none, request_latest, cpu_fallback };
    pub fn deinit(self: *MetalRecovery) void {
        self.active.deinit(self.allocator);
    }
    pub fn begin(self: *MetalRecovery, revision: Revision) !Attempt {
        const changed = !equal(self.tracked, revision);
        if (!changed and self.active.items.len >= self.maximum_attempts) return error.AttemptLimit;
        if (self.maximum_attempts == 0) return error.AttemptLimit;
        const id = try std.math.add(u64, self.next_id, 1);
        try self.active.ensureTotalCapacity(self.allocator, if (changed) 1 else self.active.items.len + 1);
        if (changed) {
            self.active.clearRetainingCapacity();
            self.failures = 0;
            self.tracked = revision;
        }
        self.next_id = id;
        self.active.appendAssumeCapacity(id);
        return .{ .revision = revision, .id = id };
    }
    fn remove(self: *MetalRecovery, id: u64) bool {
        for (self.active.items, 0..) |item, i| if (item == id) {
            _ = self.active.swapRemove(i);
            return true;
        };
        return false;
    }
    pub fn cancel(self: *MetalRecovery, attempt: Attempt) void {
        _ = self.remove(attempt.id);
    }
    pub fn complete(self: *MetalRecovery, attempt: Attempt, succeeded: bool, selected: ?Revision) Action {
        if (!equal(self.tracked, attempt.revision) or !equal(selected, attempt.revision) or !self.remove(attempt.id)) return .none;
        if (succeeded) {
            self.failures = 0;
            return .none;
        }
        self.failures +|= 1;
        if (self.failures == 1) return .request_latest;
        if (self.failures == 2) {
            self.active.clearRetainingCapacity();
            return .cpu_fallback;
        }
        return .none;
    }
    pub fn reset(self: *MetalRecovery) void {
        self.tracked = null;
        self.active.clearRetainingCapacity();
        self.failures = 0;
    }
};
pub const DropRecovery = struct {
    tracked: ?Revision = null,
    requested: bool = false,
    pub fn selected(self: *DropRecovery, revision: Revision) void {
        if (!equal(self.tracked, revision)) {
            self.tracked = revision;
            self.requested = false;
        }
    }
    pub fn dropped(self: *DropRecovery, revision: Revision, current: ?Revision, visible: bool) bool {
        if (!visible or self.requested or !equal(current, revision) or !equal(self.tracked, revision)) return false;
        self.requested = true;
        return true;
    }
    pub fn succeeded(self: *DropRecovery, revision: Revision) void {
        if (equal(self.tracked, revision)) self.requested = false;
    }
    pub fn reset(self: *DropRecovery) void {
        self.* = .{};
    }
};
