const std = @import("std");
const s = @import("spice");
const d = s.desktop_snapshot;
const p = s.presentation_policy;
const t = std.testing;
const a = t.allocator;
fn revision(value: u64) d.Revision {
    return .{ .channel = 0, .surface = .{ .id = 0, .lifecycle = 1, .value = value } };
}
test "pacing selects first frame immediately then one per display tick and pauses when idle" {
    var policy: p.Pacing = .{};
    try t.expectEqual(.select_immediately, policy.ready());
    for (0..60) |_| {
        try t.expectEqual(.wait_display_link, policy.ready());
        try t.expectEqual(.wait_display_link, policy.ready());
        try t.expectEqual(.select_on_display_link, policy.tick(true));
    }
    try t.expectEqual(.pause_display_link, policy.tick(false));
    try t.expectEqual(.select_immediately, policy.ready());
    policy.reset();
    try t.expectEqual(.pause_display_link, policy.tick(true));
}
test "cursor-only selection bypasses framebuffer and dimensions and native cursor remain exact" {
    const r = revision(1);
    try t.expect(!p.needsFramebuffer(r, r, false));
    try t.expect(p.needsFramebuffer(null, r, false));
    try t.expect(p.needsFramebuffer(r, r, true));
    try t.expect(p.needsFramebuffer(r, revision(2), false));
    try t.expectEqual(p.Size{ .width = 21, .height = 31 }, p.drawableSize(.{ .width = 10.25, .height = 15.25 }, 2));
    try t.expectEqual(p.Size{}, p.drawableSize(.{ .width = std.math.nan(f64), .height = 10 }, 2));
    try t.expectEqual(p.Size{}, p.drawableSize(.{ .width = 10, .height = 10 }, -1));
    try t.expectEqual(p.Size{}, p.drawableSize(.{ .width = std.math.floatMax(f64), .height = 1 }, 2));
    try t.expectEqual(.overlay, p.cursorLayer(.relative, true));
    try t.expectEqual(.native, p.cursorLayer(.relative, false));
    try t.expectEqual(.native, p.cursorLayer(.absolute, true));
    try t.expectEqual(.transparent, p.systemCursor(.relative, null, null, .{}, true));
    try t.expectEqual(.arrow, p.systemCursor(.relative, null, null, .{}, false));
    const payload = try s.bytes.Slice.copy(a, &.{ 1, 2, 3, 255 });
    defer payload.release();
    var c: s.cursor.Snapshot = .{ .visible = true, .payload = .{ .flags = 0, .header = .{ .unique = 1, .kind = 0, .width = 1, .height = 1, .hot_x = 0, .hot_y = 0 }, .data = payload } };
    const image = p.systemCursor(.absolute, c, .{ .width = 100, .height = 200 }, .{ .width = 250, .height = 100 }, false);
    try t.expectEqual(@as(f64, 2.5), image.image.scale_x);
    try t.expectEqual(@as(f64, 0.5), image.image.scale_y);
    c.payload.?.header.kind = 1;
    try t.expectEqual(.arrow, p.systemCursor(.absolute, c, .{ .width = 100, .height = 200 }, .{ .width = 250, .height = 100 }, true));
    c.visible = false;
    try t.expectEqual(.transparent, p.systemCursor(.absolute, c, null, .{}, true));
}
test "Metal recovery ignores duplicate retired cancelled callbacks and bounds CPU fallback" {
    var policy: p.MetalRecovery = .{ .allocator = a, .maximum_attempts = 2 };
    defer policy.deinit();
    const r = revision(1);
    const first = try policy.begin(r);
    const second = try policy.begin(r);
    try t.expectError(error.AttemptLimit, policy.begin(r));
    try t.expectEqual(.request_latest, policy.complete(first, false, r));
    try t.expectEqual(.none, policy.complete(first, false, r));
    try t.expectEqual(.cpu_fallback, policy.complete(second, false, r));
    try t.expectEqual(.none, policy.complete(second, false, r));
    const late = try policy.begin(r);
    const new = try policy.begin(revision(2));
    try t.expectEqual(.none, policy.complete(late, false, r));
    try t.expectEqual(.none, policy.complete(new, false, r));
    try t.expectEqual(.request_latest, policy.complete(new, false, revision(2)));
    const succeeded = try policy.begin(revision(2));
    try t.expectEqual(.none, policy.complete(succeeded, true, revision(2)));
    const failed_again = try policy.begin(revision(2));
    try t.expectEqual(.request_latest, policy.complete(failed_again, false, revision(2)));
    const cancelled = try policy.begin(revision(2));
    policy.cancel(cancelled);
    try t.expectEqual(.none, policy.complete(cancelled, false, revision(2)));
    policy.reset();
    try t.expectEqual(.none, policy.complete(failed_again, false, revision(2)));
}
fn allocationFailures(alloc: std.mem.Allocator) !void {
    var policy: p.MetalRecovery = .{ .allocator = alloc };
    defer policy.deinit();
    const first = policy.begin(revision(1)) catch |err| {
        try t.expect(policy.tracked == null);
        return err;
    };
    _ = try policy.begin(revision(2));
    try t.expectEqual(.none, policy.complete(first, false, revision(1)));
}
test "attempt allocation failure leaves policy unchanged" {
    try t.checkAllAllocationFailures(a, allocationFailures, .{});
}
test "drawable drop only retries visible selected revision until success or replacement" {
    var policy: p.DropRecovery = .{};
    const r = revision(1);
    policy.selected(r);
    try t.expect(!policy.dropped(r, r, false));
    try t.expect(policy.dropped(r, r, true));
    try t.expect(!policy.dropped(r, r, true));
    policy.succeeded(revision(2));
    try t.expect(!policy.dropped(r, r, true));
    policy.succeeded(r);
    try t.expect(policy.dropped(r, r, true));
    policy.selected(revision(2));
    try t.expect(!policy.dropped(r, revision(2), true));
    try t.expect(policy.dropped(revision(2), revision(2), true));
    policy.reset();
    try t.expect(!policy.dropped(revision(2), revision(2), true));
}
