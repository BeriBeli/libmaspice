const std = @import("std");
const s = @import("spice");
const a = std.heap.c_allocator;
export fn video_fixture_create(codec: u8, width: usize, height: usize) ?*s.video.Decoder {
    const p = a.create(s.video.Decoder) catch return null;
    p.* = s.video.Decoder.init(a, if (codec == 0) .h264 else .h265, width, height, .{}) catch {
        a.destroy(p);
        return null;
    };
    return p;
}
export fn video_fixture_destroy(p: ?*s.video.Decoder) void {
    if (p) |decoder| {
        decoder.deinit();
        a.destroy(decoder);
    }
}
export fn video_fixture_decode(p: *s.video.Decoder, bytes: [*]const u8, len: usize, time: u32, out: *?*s.video.Frame) c_int {
    out.* = null;
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const frame = p.decode(bytes[0..len], time, &token) catch |err| {
        std.debug.print("video: {s}, native={d}\n", .{ @errorName(err), p.last_status });
        return -1;
    };
    if (frame) |value| {
        const owned = a.create(s.video.Frame) catch {
            value.deinit();
            return -1;
        };
        owned.* = value;
        out.* = owned;
        return 1;
    }
    return 0;
}
export fn video_fixture_frame_release(frame: *s.video.Frame) void {
    frame.deinit();
    a.destroy(frame);
}
export fn video_fixture_pixels(frame: *s.video.Frame, out: [*]u8, len: usize) c_int {
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const image = frame.copyBGRA(a, &token) catch return -1;
    defer image.release();
    if (image.pixels().len != len) return -1;
    @memcpy(out[0..len], image.pixels());
    return 0;
}
export fn video_fixture_stats(decoder: *s.video.Decoder, stats: *[6]usize) void {
    const d = decoder.stats;
    stats.* = .{ d.sessions, d.hardware, d.software, d.query_failed, d.frames, d.dropped };
}
extern "c" fn video_probe_frame(u32, u32, c_int, c_int, [*]const u8, [*]const u8) ?*anyopaque;
export fn video_fixture_synthetic(width: u32, height: u32, full: c_int, matrix: c_int, y: [*]const u8, uv: [*]const u8) ?*s.video.Frame {
    const pixel = video_probe_frame(width, height, full, matrix, y, uv) orelse return null;
    const value = s.video.Frame.take(pixel, width, height, .{}) catch return null;
    const out = a.create(s.video.Frame) catch {
        value.deinit();
        return null;
    };
    out.* = value;
    return out;
}
export fn video_fixture_gpu(frame: *s.video.Frame, path: [*:0]const u8, out: [*]u8, len: usize) c_int {
    if (len != frame.width * frame.height * 4) return -1;
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const context = s.graphics.Context.init(path) catch return -2;
    defer context.deinit();
    const dst = context.create(a, frame.width, frame.height) catch return -3;
    defer dst.release();
    const rect: s.region.Rect = .{ .x = 0, .y = 0, .width = @intCast(frame.width), .height = @intCast(frame.height) };
    context.composeVideo(frame.*, dst, rect, rect, &.{rect}, false, &token) catch |err| {
        return switch (err) {
            error.UnsupportedColorMatrix, error.UnsupportedPlaneGeometry => 1,
            else => -4,
        };
    };
    const map = dst.lock(false) catch return -5;
    defer map.unlock() catch {};
    for (0..frame.height) |row| @memcpy(out[row * frame.width * 4 ..][0 .. frame.width * 4], map.bytes[row * map.stride ..][0 .. frame.width * 4]);
    return 0;
}
