const std = @import("std");
const h = @import("spice").host_input;
const expect = std.testing.expect;
const eq = std.testing.expectEqual;

test "keyboard decimal exception, held sides, repeats and focus cleanup" {
    try eq(@as(?u16, 0x34), h.scanCode(65, 0, true));
    try eq(@as(?u16, 0x53), h.scanCode(65, h.numeric_pad, true));
    try eq(@as(?u16, null), h.scanCode(65535, 0, false));
    var k: h.Keyboard = .{};
    var b = k.flagsChanged(0, h.shift | 4);
    try eq(@as(u32, 0x36), b.events()[0].key_down);
    b = k.flagsChanged(0, h.shift);
    try eq(@as(usize, 0), b.length);
    b = k.key(true, 0, h.shift, false).?;
    try eq(@as(usize, 1), b.length);
    try eq(@as(u32, 0x1e), b.events()[0].key_down);
    b = k.key(true, 0, h.shift, false).?;
    try eq(@as(usize, 1), b.length);
    b = k.releaseAll();
    try eq(@as(usize, 2), b.length);
    b = k.releaseAll();
    try eq(@as(usize, 0), b.length);
    b = k.flagsChanged(0, 0);
    try eq(@as(usize, 0), b.length);
    for (0..128) |code| _ = k.key(true, @intCast(code), h.shift | h.control | h.option | h.command, false);
    b = k.releaseAll();
    try expect(b.length > 90);
    try expect(b.length < 128);
}
test "geometry rejects invalid values and excludes maximum edge" {
    const rect: h.Rect = .{ .x = 20, .y = 40, .width = 800, .height = 600 };
    try eq(h.Rect{ .x = 20, .y = 140, .width = 800, .height = 400 }, h.contentRect(rect, 400, 200));
    try expect(h.absolute(rect, 400, 200, .{ .x = 820, .y = 140 }) == null);
    try expect(h.absolute(rect, 400, 200, .{ .x = 20, .y = 540 }) == null);
    const pos = h.absolute(rect, 400, 200, .{ .x = 819.99, .y = 539.99 }).?.position;
    try eq(@as(u32, 399), pos.x);
    try eq(@as(u32, 199), pos.y);
    try expect(h.absolute(rect, 0, 0, .{}) == null);
    try expect(h.absolute(rect, 400, 200, .{ .x = std.math.nan(f64) }) == null);
    try eq(h.Rect{}, h.contentRect(.{ .width = std.math.inf(f64), .height = 1 }, 1, 1));
    try eq(h.Rect{}, h.contentRect(.{ .x = std.math.floatMax(f64), .width = std.math.floatMax(f64), .height = 1 }, 1, 1));
    try eq(@as(i32, 0), h.delta(std.math.nan(f64)));
    try eq(@as(i32, 1), h.delta(0.5));
    try eq(@as(i32, -1), h.delta(-0.5));
    try eq(std.math.maxInt(i32), h.delta(1e100));
    try eq(std.math.minInt(i32), h.delta(-1e100));
    try expect(h.relative(false, 1, 1) == null);
    try expect(h.relative(true, 0.4, -0.4) == null);
    try eq(@as(usize, 0), h.scroll(std.math.inf(f64)).length);
    try eq(@as(usize, 2), h.scroll(-0.1).length);
    try eq(@import("spice").inputs.Button.extra, h.otherButton(4));
}
const System = struct {
    events: [32]u8 = undefined,
    count: usize = 0,
    success: bool = true,
    point: ?h.Point = .{ .x = 20, .y = 30 },
    fn log(self: *System, v: u8) void {
        self.events[self.count] = v;
        self.count += 1;
    }
    fn cast(p: *anyopaque) *System {
        return @ptrCast(@alignCast(p));
    }
    fn location(p: *anyopaque) ?h.Point {
        const s = cast(p);
        s.log('l');
        return s.point;
    }
    fn disconnect(p: *anyopaque) bool {
        const s = cast(p);
        s.log('d');
        return s.success;
    }
    fn warp(p: *anyopaque, point: h.Point) void {
        const s = cast(p);
        std.debug.assert(point.x == 20 and point.y == 30);
        s.log('w');
    }
    fn reconnect(p: *anyopaque) void {
        cast(p).log('r');
    }
    fn hide(p: *anyopaque) void {
        cast(p).log('h');
    }
    fn unhide(p: *anyopaque) void {
        cast(p).log('u');
    }
    fn api(self: *System) h.CaptureSystem {
        return .{ .context = self, .location = location, .disconnect = disconnect, .warp = warp, .reconnect = reconnect, .hide = hide, .unhide = unhide };
    }
};
test "capture balances native hide, restore and disconnect, including failure and missing location" {
    var s: System = .{ .success = false };
    var capture: h.Capture = .{};
    try expect(!capture.acquire(s.api()));
    capture.release(s.api());
    try std.testing.expectEqualStrings("ld", s.events[0..s.count]);
    s.count = 0;
    s.success = true;
    try expect(capture.acquire(s.api()));
    try expect(capture.acquire(s.api()));
    capture.release(s.api());
    capture.release(s.api());
    try std.testing.expectEqualStrings("ldhwru", s.events[0..s.count]);
    s.count = 0;
    s.point = null;
    try expect(capture.acquire(s.api()));
    capture.release(s.api());
    try std.testing.expectEqualStrings("ldhru", s.events[0..s.count]);
}
