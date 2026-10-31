const std = @import("std");
const s = @import("spice");
const a = std.heap.c_allocator;
const State = struct { pool: s.codec_executor.Executor = .{}, decoder: s.glz.Decoder, token: s.cancel.Token = .{} };
pub export fn glz_fixture_create() ?*State {
    const state = a.create(State) catch return null;
    state.* = .{ .decoder = undefined };
    state.decoder = s.glz.Decoder.init(a, &state.pool, .{ .waits = 0 });
    return state;
}
pub export fn glz_fixture_destroy(state: *State) void {
    state.decoder.deinit();
    state.token.deinit();
    state.pool.deinit();
    a.destroy(state);
}
pub export fn glz_fixture_clear(state: *State) c_int {
    state.decoder.clear() catch return -1;
    return 0;
}
pub export fn glz_fixture_decode(state: *State, input: [*]const u8, size: usize, width: usize, height: usize, out: *?*s.image.Image) c_int {
    out.* = null;
    const result = state.decoder.decode(input[0..size], width, height, 0, &state.token) catch return -1;
    const handle = a.create(s.image.Image) catch {
        result.release();
        return -1;
    };
    handle.* = result;
    out.* = handle;
    return 0;
}
pub export fn glz_fixture_pixels(image: *s.image.Image, size: *usize) [*]const u8 {
    size.* = image.pixels().len;
    return image.pixels().ptr;
}
pub export fn glz_fixture_flags(image: *s.image.Image) c_int {
    return @as(c_int, @intFromBool(image.top_down)) | (@as(c_int, @intFromBool(image.alpha == .straight)) << 1);
}
pub export fn glz_fixture_release(image: *s.image.Image) void {
    image.release();
    a.destroy(image);
}
pub export fn glz_fixture_inflate(input: [*]const u8, size: usize, output: [*]u8, exact: usize) c_int {
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const bytes = s.zlib.inflate(a, input[0..size], exact, .{}, &token) catch return -1;
    defer a.free(bytes);
    @memcpy(output[0..exact], bytes);
    return 0;
}
pub export fn glz_fixture_native(kind: c_int, input: [*]const u8, size: usize, width: usize, height: usize, out: *?*s.image.Image) c_int {
    out.* = null;
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const image: s.image.Image = if (kind == 1) s.native_codecs.quic(a, input[0..size], width, height, .{}, &token) catch return -1 else blk: {
        var decoder = s.native_codecs.JPEG.init() catch return -1;
        defer decoder.deinit();
        break :blk decoder.decode(a, input[0..size], width, height, .{}, &token) catch return -1;
    };
    const handle = a.create(s.image.Image) catch {
        image.release();
        return -1;
    };
    handle.* = image;
    out.* = handle;
    return 0;
}
pub export fn glz_fixture_display_parse(kind: u16, input: [*]const u8, size: usize) c_int {
    var parsed = s.display_wire.decode(a, kind, input[0..size]) catch return -1;
    parsed.deinit();
    return 0;
}

export fn glz_fixture_stream_parse(kind: u16, data: [*]const u8, len: usize) c_int {
    var parsed = s.stream_wire.decode(std.heap.c_allocator, kind, data[0..len]) catch return -1;
    defer parsed.deinit();
    return 0;
}
fn annexOutput(codec: u8, data: []const u8, output: []u8) !usize {
    const unit = try s.annexb.parse(a, if (codec == 0) .h264 else .h265, data, .{});
    defer unit.deinit();
    var writer: s.bytes.Writer = .{ .allocator = a, .limit = output.len };
    defer writer.deinit();
    try writer.write(u8, @intFromBool(unit.picture));
    try writer.write(u8, @intFromBool(unit.random_access));
    try writer.write(u32, @intCast(unit.nals.len));
    try writer.write(u32, @intCast(unit.sample.len));
    try writer.append(unit.sample);
    for (unit.nals) |nal| {
        try writer.write(u8, nal.kind);
        try writer.write(u32, @intCast(nal.bytes.len));
        try writer.append(nal.bytes);
    }
    @memcpy(output[0..writer.bytes.items.len], writer.bytes.items);
    return writer.bytes.items.len;
}
export fn glz_fixture_annexb(codec: u8, data: [*]const u8, len: usize, output: [*]u8, capacity: usize) isize {
    return @intCast(annexOutput(codec, data[0..len], output[0..capacity]) catch return -1);
}
