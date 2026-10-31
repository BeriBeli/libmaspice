const std = @import("std");
const s = @import("spice");
const data = @import("video_data");
const t = std.testing;
const a = t.allocator;
extern "c" fn video_probe_fail_session() void;
extern "c" fn video_probe_hardware(c_int) void;
fn allocationRun(allocator: std.mem.Allocator) !void {
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var decoder = try s.video.Decoder.init(allocator, .h264, 128, 128, .{});
    defer decoder.deinit();
    const frame = (try decoder.decode(data.baseline, 1, &token)).?;
    defer frame.deinit();
    const second = (try decoder.decode(data.high, 2, &token)).?;
    defer second.deinit();
    const image = try frame.copyBGRA(allocator, &token);
    defer image.release();
    try t.expectEqual(@as(usize, 65536), image.pixels().len);
}
test "all allocation failures free parameters, AVCC owner, decoded frames and old session" {
    try t.checkAllAllocationFailures(a, allocationRun, .{});
}
test "hardware query failures and software sessions are rejected and identical parameters can retry" {
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var decoder = try s.video.Decoder.init(a, .h264, 128, 128, .{});
    defer decoder.deinit();
    video_probe_hardware(1);
    try t.expectError(error.VideoHardwareUnavailable, decoder.decode(data.baseline, 0, &token));
    try t.expect(decoder.session == null and decoder.dirty);
    video_probe_hardware(2);
    try t.expectError(error.VideoHardwareQueryFailed, decoder.decode(data.baseline, 1, &token));
    try t.expect(decoder.session == null and decoder.dirty);
    const frame = (try decoder.decode(data.baseline, 2, &token)).?;
    defer frame.deinit();
    try t.expectEqual(@as(usize, 1), decoder.stats.hardware);
    try t.expectEqual(@as(usize, 1), decoder.stats.software);
    try t.expectEqual(@as(usize, 1), decoder.stats.query_failed);
}
test "failed session replacement preserves prior session and retained frame then retries identical parameters" {
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var decoder = try s.video.Decoder.init(a, .h264, 128, 128, .{});
    defer decoder.deinit();
    const first = (try decoder.decode(data.baseline, 0, &token)).?;
    defer first.deinit();
    const old = decoder.session;
    video_probe_fail_session();
    try t.expectError(error.VideoSessionFailed, decoder.decode(data.high, 1, &token));
    try t.expect(decoder.session == old and decoder.dirty);
    const second = (try decoder.decode(data.high, 2, &token)).?;
    defer second.deinit();
    try t.expectEqual(@as(usize, 2), decoder.stats.hardware);
    try t.expect(!decoder.dirty);
    const image = try first.copyBGRA(a, &token);
    defer image.release();
    try t.expectEqual(@as(usize, 65536), image.pixels().len);
}
test "missing parameters, invalid SPS, dimensions, parser limits and cancellation do not publish" {
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var decoder = try s.video.Decoder.init(a, .h264, 128, 128, .{});
    defer decoder.deinit();
    try t.expectError(error.MissingParameterSets, decoder.decode(&.{ 0, 0, 1, 0x65, 1 }, 0, &token));
    const frame = (try decoder.decode(data.baseline, 1, &token)).?;
    defer frame.deinit();
    const previous = decoder.session;
    try t.expectError(error.UnsupportedVideoFormat, decoder.decode(&.{ 0, 0, 1, 0x67, 1 }, 2, &token));
    try t.expect(decoder.session == previous);
    const again = (try decoder.decode(data.baseline, 3, &token)).?;
    defer again.deinit();
    var wrong = try s.video.Decoder.init(a, .h264, 127, 128, .{});
    defer wrong.deinit();
    try t.expectError(error.DimensionMismatch, wrong.decode(data.baseline, 4, &token));
    decoder.limits.parser.encoded = 2;
    try t.expectError(error.EncodedImageTooLarge, decoder.decode(data.baseline, 5, &token));
    token.cancel();
    try t.expectError(error.Cancelled, decoder.decode(data.baseline, 6, &token));
    try t.expectEqual(@as(usize, 2), decoder.stats.frames);
}
extern "c" fn video_probe_frame(u32, u32, c_int, c_int, [*]const u8, [*]const u8) ?*anyopaque;
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
test "NV12 Surface composition preserves crop flip clips and old immutable snapshots" {
    const path = getenv("SPICE_ZIG_TEST_METALLIB") orelse return error.MissingTestMetallib;
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const context = try s.graphics.Context.init(path);
    defer context.deinit();
    const luma = [_]u8{ 16, 235, 16, 235, 235, 16, 235, 16, 16, 235, 16, 235, 235, 16, 235, 16 };
    const uv = [_]u8{ 128, 128, 128, 128, 128, 128, 128, 128 };
    const frame = try s.video.Frame.take(video_probe_frame(4, 4, 0, 601, &luma, &uv).?, 4, 4, .{});
    defer frame.deinit();
    const cpu = try frame.copyBGRA(a, &token);
    defer cpu.release();
    var native = s.surface.Store.init(a, .{}, context);
    defer native.deinit();
    var fallback = s.surface.Store.init(a, .{}, null);
    defer fallback.deinit();
    try native.create(7, 6, 6, 32, &token);
    try fallback.create(7, 6, 6, 32, &token);
    const full: s.region.Rect = .{ .x = 0, .y = 0, .width = 6, .height = 6 };
    _ = try native.fill(7, &.{full}, 0xff513121, &token);
    _ = try fallback.fill(7, &.{full}, 0xff513121, &token);
    const previous = try native.snapshot(7);
    defer previous.deinit();
    const src: s.region.Rect = .{ .x = 1, .y = 1, .width = 2, .height = 2 };
    const clip: s.region.Rect = .{ .x = 1, .y = 2, .width = 4, .height = 3 };
    const n = try native.admitVideo(7);
    const f = try fallback.admitVideo(7);
    _ = (try native.drawNativeVideo(7, frame, src, full, &.{clip}, true, n.barrier, n.sequence, &token)).?;
    _ = (try fallback.drawScaledVideo(7, cpu, true, src, full, &.{clip}, true, f.barrier, f.sequence, &token)).?;
    const actual = try native.snapshot(7);
    defer actual.deinit();
    const expected = try fallback.snapshot(7);
    defer expected.deinit();
    try t.expect(actual.advanced_video and expected.advanced_video and !previous.advanced_video);
    const gpu = try actual.backing.read();
    defer gpu.finish() catch {};
    const cpu_pixels = try expected.backing.read();
    defer cpu_pixels.finish() catch {};
    for (0..6) |y| {
        try t.expectEqualSlices(u8, cpu_pixels.bytes[y * cpu_pixels.stride ..][0..24], gpu.bytes[y * gpu.stride ..][0..24]);
    }
    const old = try previous.backing.read();
    defer old.finish() catch {};
    try t.expectEqualSlices(u8, &.{ 0x21, 0x31, 0x51, 0xff }, old.bytes[0..4]);
    // Every stream reserves from the same Surface counter; late older work has
    // no effect after a later stream publishes or CPU mutation advances barrier.
    const earlier = try native.admitVideo(7);
    const later = try native.admitVideo(7);
    try t.expect(later.sequence.value > earlier.sequence.value);
    _ = (try native.drawNativeVideo(7, frame, src, full, &.{clip}, false, later.barrier, later.sequence, &token)).?;
    try t.expectEqual(@as(?s.surface.Revision, null), try native.drawNativeVideo(7, frame, src, full, &.{clip}, false, earlier.barrier, earlier.sequence, &token));
    const still_advanced = try native.snapshot(7);
    defer still_advanced.deinit();
    try t.expect(still_advanced.advanced_video);
    const pending = try fallback.admitVideo(7);
    _ = try fallback.fill(7, &.{full}, 0xff000000, &token);
    try t.expectEqual(@as(?s.surface.Revision, null), try fallback.drawScaledVideo(7, cpu, true, src, full, &.{clip}, false, pending.barrier, pending.sequence, &token));
    const after_fill = try fallback.snapshot(7);
    defer after_fill.deinit();
    try t.expect(!after_fill.advanced_video);
}
fn streamConfig(codec: s.stream_wire.Codec) s.stream_wire.Create {
    return .{ .surface = 1, .id = 0, .top_down = true, .codec = codec, .stamp = 0, .width = 128, .height = 128, .source_width = 128, .source_height = 128, .destination = .{ .x = 0, .y = 0, .width = 128, .height = 128 }, .clips = null };
}
test "late advanced input still decodes reference state while late MJPEG skips decode" {
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var store = s.surface.Store.init(a, .{}, null);
    defer store.deinit();
    try store.create(1, 128, 128, 32, &token);
    var pool: s.codec_executor.Executor = .{};
    defer pool.deinit();
    var media = try s.clock.Clock.init();
    defer media.deinit();
    media.reset(100000);
    var advanced = try s.stream_decoder.Stream.init(a, &store, streamConfig(.h264));
    defer advanced.deinit();
    const payload = try s.bytes.Slice.copy(a, data.baseline);
    defer payload.release();
    var job = try advanced.prepare(&store, payload, 0, null, null);
    defer job.deinit();
    try t.expectEqual(@as(?s.surface.Revision, null), try advanced.render(job, &store, &pool, &media, &token));
    try t.expectEqual(@as(usize, 1), advanced.backend.advanced.stats.frames);
    try t.expectEqual(@as(usize, 1), advanced.stats.dropped_after_decode);
    const snapshot = try store.snapshot(1);
    defer snapshot.deinit();
    try t.expectEqual(@as(u64, 0), snapshot.revision.value);
    var jpeg = try s.stream_decoder.Stream.init(a, &store, streamConfig(.mjpeg));
    defer jpeg.deinit();
    const invalid = try s.bytes.Slice.copy(a, &.{ 1, 2, 3 });
    defer invalid.release();
    var jpeg_job = try jpeg.prepare(&store, invalid, 0, null, null);
    defer jpeg_job.deinit();
    try t.expectEqual(@as(?s.surface.Revision, null), try jpeg.render(jpeg_job, &store, &pool, &media, &token));
    try t.expectEqual(@as(usize, 1), jpeg.stats.dropped_before_decode);
    try t.expectEqual(@as(usize, 0), jpeg.stats.decoded);
    // Same H.264 decoder remains usable, and CPU fallback really publishes.
    const next = (try advanced.render(job, &store, &pool, null, &token)).?;
    try t.expectEqual(@as(u64, 1), next.value);
    try t.expectEqual(@as(usize, 1), advanced.stats.cpu_fallback);
}
test {
    _ = @import("scheduler_tests.zig");
}
