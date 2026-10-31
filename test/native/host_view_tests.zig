const std = @import("std");
const s = @import("spice");
const t = std.testing;
const a = t.allocator;
const C = s.host_view.Controller;
const Fake = struct {
    queue: [64]*C = undefined,
    queued: usize = 0,
    destroyed: usize = 0,
    ticking: bool = false,
    cpu: bool = false,
    errors: usize = 0,
    events: [64]s.inputs.Input = undefined,
    event_count: usize = 0,
    captures: usize = 0,
    releases: usize = 0,
    close_on_input: ?*C = null,
    fn cast(p: *anyopaque) *Fake {
        return @ptrCast(@alignCast(p));
    }
    fn destroy(p: *anyopaque) void {
        cast(p).destroyed += 1;
    }
    fn schedule(p: *anyopaque, c: *C) void {
        const f = cast(p);
        f.queue[f.queued] = c;
        f.queued += 1;
    }
    fn drain(f: *Fake) void {
        while (f.queued > 0) {
            const c = f.queue[0];
            f.queued -= 1;
            std.mem.copyForwards(*C, f.queue[0..f.queued], f.queue[1..][0..f.queued]);
            c.ready();
            c.release();
        }
    }
    fn setTicking(p: *anyopaque, active: bool) void {
        cast(p).ticking = active;
    }
    fn layout(_: *anyopaque, _: s.host_input.Rect, _: s.presentation_policy.Size) void {}
    fn draw(_: *anyopaque, c: *C) s.host_view.DrawResult {
        return c.submit(null);
    }
    fn content(p: *anyopaque, kind: s.host_view.Content) void {
        cast(p).cpu = kind == .cpu;
    }
    fn cursor(_: *anyopaque, _: s.host_view.Cursor) void {}
    fn input(p: *anyopaque, e: s.inputs.Input) void {
        const f = cast(p);
        f.events[f.event_count] = e;
        f.event_count += 1;
        if (f.close_on_input) |c| {
            f.close_on_input = null;
            c.close();
            c.release();
        }
    }
    fn failure(p: *anyopaque, _: anyerror) void {
        cast(p).errors += 1;
    }
    fn location(_: *anyopaque) ?s.host_input.Point {
        return .{ .x = 7, .y = 8 };
    }
    fn disconnect(p: *anyopaque) bool {
        cast(p).captures += 1;
        return true;
    }
    fn warp(_: *anyopaque, _: s.host_input.Point) void {}
    fn reconnect(p: *anyopaque) void {
        cast(p).releases += 1;
    }
    fn noop(_: *anyopaque) void {}
    fn host(f: *Fake) s.host_view.Host {
        return .{ .context = f, .destroy = destroy, .schedule = schedule, .ticking = setTicking, .layout = layout, .draw = draw, .content = content, .cursor = cursor, .input = input, .failure = failure, .capture = .{ .context = f, .location = location, .disconnect = disconnect, .warp = warp, .reconnect = reconnect, .hide = noop, .unhide = noop } };
    }
};
fn publish(src: *s.desktop_source.Source, store: *s.surface.Store, token: *s.cancel.Token, color: u32) !void {
    const revision = (try store.fill(0, &.{.{ .x = 0, .y = 0, .width = 4, .height = 2 }}, color, token)).?;
    const publication = (try store.publicationSnapshot(revision)).?;
    defer publication.release();
    try src.receiveFrame(0, publication);
}
test "host view coalesces, ACKs selected frame, redraws geometry and drains queued destruction" {
    const src = try s.desktop_source.Source.create(a, .{});
    defer src.release();
    try src.begin(.absolute, false, true);
    var store = s.surface.Store.init(a, .{}, null);
    defer store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try store.create(0, 4, 2, 32, &token);
    var f: Fake = .{};
    const c = try C.create(a, src, .{}, f.host(), null, null);
    var owned = true;
    defer {
        if (owned) {
            c.close();
            c.release();
        }
        f.drain();
    }
    c.configure(true, .{ .width = 80, .height = 80 }, 2);
    f.drain();
    c.tick();
    try publish(src, &store, &token, 0xff123456);
    try publish(src, &store, &token, 0xffabcdef);
    try t.expectEqual(@as(usize, 1), f.queued);
    f.drain();
    try t.expect(f.cpu and c.selected != null);
    try t.expectEqual(@as(u64, 2), c.selected.?.surface.value);
    const pixels = try c.cpuFrame().?.publication.pixels();
    try t.expectEqualSlices(u8, &.{ 0xef, 0xcd, 0xab, 0xff }, pixels[0..4]);
    const selected = c.selected.?;
    c.configure(true, .{ .width = 100, .height = 50 }, 1);
    f.drain();
    c.tick();
    try t.expect(c.selected.?.equal(selected));
    try t.expect(!c.redraw);
    c.configure(false, .{}, 1);
    try t.expect(c.cpuFrame() == null and !f.ticking and src.metrics().visible == 0);
    c.configure(true, .{ .width = 100, .height = 50 }, 1);
    f.drain();
    try t.expect(c.cpuFrame() != null);
    try src.updatePointer(.relative);
    f.drain();
    c.tick();
    c.button(true, .left, true);
    try t.expectEqual(@as(usize, 1), f.captures);
    try t.expect(c.key(true, 0, 0, false));
    try src.updatePointer(.absolute); // Queue deliberately survives close.
    c.close();
    c.release();
    owned = false;
    try t.expectEqual(@as(usize, 1), f.releases);
    try t.expectEqual(@as(usize, 0), src.metrics().subscriptions);
    try t.expectEqual(@as(usize, 0), f.destroyed);
    f.drain();
    try t.expectEqual(@as(usize, 1), f.destroyed);
    try t.expectEqual(@as(usize, 0), f.errors);
    try t.expectEqualDeep(s.inputs.Input{ .key_up = 0x1e }, f.events[f.event_count - 1]);
}
test "input callback can close and release its native owner during modifier batch" {
    const src = try s.desktop_source.Source.create(a, .{});
    defer src.release();
    var f: Fake = .{};
    const c = try C.create(a, src, .{}, f.host(), null, null);
    f.close_on_input = c;
    try t.expect(c.key(true, 0, s.host_input.shift, false));
    try t.expectEqual(@as(usize, 1), f.destroyed);
    try t.expectEqual(@as(usize, 0), src.metrics().subscriptions);
    // Modifier down triggered close; both held keys released, remaining key-down suppressed.
    try t.expectEqual(@as(usize, 3), f.event_count);
    try t.expectEqualDeep(s.inputs.Input{ .key_down = 0x2a }, f.events[0]);
    try t.expectEqualDeep(s.inputs.Input{ .key_up = 0x1e }, f.events[1]);
    try t.expectEqualDeep(s.inputs.Input{ .key_up = 0x2a }, f.events[2]);
}
fn createFailure(allocator: std.mem.Allocator) !void {
    const src = try s.desktop_source.Source.create(allocator, .{});
    defer src.release();
    var f: Fake = .{};
    const c = try C.create(allocator, src, .{}, f.host(), null, null);
    c.close();
    c.release();
    try t.expectEqual(@as(usize, 1), f.destroyed);
    try t.expectEqual(@as(usize, 0), src.metrics().subscriptions);
}
test "host creation allocation failures release subscription and Source ownership" {
    try t.checkAllAllocationFailures(a, createFailure, .{});
}
