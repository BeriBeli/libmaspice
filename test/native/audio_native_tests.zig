const std = @import("std");
const t = std.testing;
const a = t.allocator;
const s = @import("spice");
const n = s.audio_native;
extern fn audio_probe_format(u32, u32, u32, u32) ?*anyopaque;
extern fn audio_probe_input(*anyopaque, u32, u32) ?*anyopaque;
extern fn audio_probe_release(*anyopaque) void;
extern fn audio_probe_shorten(*anyopaque) void;
extern fn spice_zig_audio_buffer_at(*anyopaque, u32, *n.Buffer) c_int;
extern fn audio_probe_list(*anyopaque) *anyopaque;
extern fn audio_oracle_create(*anyopaque, u32, u32, u32, usize, usize) ?*anyopaque;
extern fn audio_oracle_destroy(*anyopaque) void;
extern fn audio_oracle_capture(*anyopaque, *anyopaque, u32) void;
extern fn audio_oracle_drain(*anyopaque, *[9]u64) void;
extern fn audio_oracle_packet(*anyopaque, usize, [*]u8, usize, *[2]u64) c_int;
fn compare(converter: *n.Converter, oracle: *anyopaque) !void {
    const drain = try converter.queue.drain(a);
    defer drain.deinit();
    var expected: [9]u64 = undefined;
    audio_oracle_drain(oracle, &expected);
    const d = converter.diagnostics();
    const actual = [_]u64{ drain.packets.len, drain.dropped_bytes, if (drain.failure) |v| @as(u64, @backingInt(v)) + 1 else 0, d.input_callbacks, d.input_frames, d.split_callbacks, d.conversion_passes, d.conversion_failures, d.converted_frames };
    try t.expectEqualSlices(u64, &expected, &actual);
    const scratch = try a.alloc(u8, 1024 * 1024);
    defer a.free(scratch);
    for (drain.packets, 0..) |packet, index| {
        var meta: [2]u64 = undefined;
        try t.expectEqual(@as(c_int, 0), audio_oracle_packet(oracle, index, scratch.ptr, scratch.len, &meta));
        try t.expectEqual(meta[0], packet.timestamp);
        try t.expectEqualSlices(u8, scratch[0..@intCast(meta[1])], packet.bytes);
    }
}
test "Apple converter chunk timestamps and exact PCM match original Swift across formats rates and malformed recovery" {
    const configs = [_][5]u32{ .{ 8000, 8000, 2, 0, 1 }, .{ 48000, 44100, 2, 1, 0 }, .{ 44100, 48000, 1, 1, 1 }, .{ 96000, 8000, 2, 1, 0 }, .{ 8000, 192000, 1, 0, 1 }, .{ 48000, 48000, 2, 1, 0 } };
    for (configs) |c| {
        const format = audio_probe_format(c[0], c[2], c[3], c[4]) orelse {
            std.debug.print("unsupported probe format {any}\n", .{c});
            return error.TestFormat;
        };
        defer audio_probe_release(format);
        var converter = try n.Converter.init(a, format, c[1], c[2], 1024, .{ .bytes = 1024 * 1024, .slots = 4096 });
        defer converter.deinit();
        const oracle = audio_oracle_create(format, c[1], c[2], 1024, 1024 * 1024, 4096) orelse return error.TestOracle;
        defer audio_oracle_destroy(oracle);
        for ([_]u32{ 0, 1, 1024, 1025, 2051, 4097 }) |frames| {
            const input = audio_probe_input(format, frames, frames) orelse return error.TestInput;
            defer audio_probe_release(input);
            converter.capture(input, 0xfffffff0);
            audio_oracle_capture(oracle, input, 0xfffffff0);
            try compare(&converter, oracle);
        }
        const other_format = audio_probe_format(if (c[0] == 8000) 16000 else 8000, c[2], c[3], c[4]).?;
        defer audio_probe_release(other_format);
        const other = audio_probe_input(other_format, 1025, 7).?;
        defer audio_probe_release(other);
        converter.capture(other, 100);
        audio_oracle_capture(oracle, other, 100);
        try compare(&converter, oracle);
        const invalid = audio_probe_input(format, 1025, 8).?;
        defer audio_probe_release(invalid);
        audio_probe_shorten(invalid);
        converter.capture(invalid, 200);
        audio_oracle_capture(oracle, invalid, 200);
        try compare(&converter, oracle);
        const recovered = audio_probe_input(format, 1025, 9).?;
        defer audio_probe_release(recovered);
        converter.capture(recovered, 300);
        audio_oracle_capture(oracle, recovered, 300);
        try compare(&converter, oracle);
    }
}
fn converterAllocations(allocator: std.mem.Allocator, format: *anyopaque) !void {
    var converter = try n.Converter.init(allocator, format, 8000, 2, 1024, .{ .bytes = 4096, .slots = 1024 });
    defer converter.deinit();
}
test "Apple conversion owners clean every Zig allocation failure and bound native preallocation" {
    const format = audio_probe_format(8000, 2, 0, 1).?;
    defer audio_probe_release(format);
    try t.checkAllAllocationFailures(a, converterAllocations, .{format});
    try t.expectError(error.InvalidAudioCapacity, n.Converter.init(a, format, 8000, 8, 2000000, .{ .bytes = 4096, .slots = 1 }));
    try t.expectEqual(@as(u32, 112), n.Converter.chunkTimestamp(0xfffffff0, 1024, 8000));
}
test "production ABL render adapter silences undersized and secondary buffers without consuming PCM" {
    var playback = try s.audio_buffer.Playback.init(a, .{ .bytes = 16, .slots = 4 }, 4, 8000, 0);
    defer playback.deinit();
    _ = playback.enqueue(0, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    const interleaved = audio_probe_format(8000, 2, 0, 1).?;
    defer audio_probe_release(interleaved);
    const pcm = audio_probe_input(interleaved, 2, 2).?;
    defer audio_probe_release(pcm);
    n.renderList(&playback, 3, audio_probe_list(pcm));
    var output: n.Buffer = undefined;
    try t.expectEqual(@as(c_int, 0), spice_zig_audio_buffer_at(pcm, 0, &output));
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, output.data.?[0..8]);
    try t.expectEqual(@as(usize, 8), playback.queue.diagnostics().queued_bytes);
    n.renderList(&playback, 2, audio_probe_list(pcm));
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, output.data.?[0..8]);
    try t.expectEqual(@as(usize, 0), playback.queue.diagnostics().queued_bytes);
    // Same adapter sees a planar list: first undersized and all secondary
    // destinations must be silent; the interleaved queue remains intact.
    const planar = audio_probe_format(8000, 2, 0, 0).?;
    defer audio_probe_release(planar);
    const planes = audio_probe_input(planar, 2, 3).?;
    defer audio_probe_release(planes);
    _ = playback.enqueue(0, &.{ 1, 2, 3, 4 });
    n.renderList(&playback, 2, audio_probe_list(planes));
    for (0..2) |index| {
        try t.expectEqual(@as(c_int, 0), spice_zig_audio_buffer_at(planes, @intCast(index), &output));
        try t.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, output.data.?[0..4]);
    }
    try t.expectEqual(@as(usize, 4), playback.queue.diagnostics().queued_bytes);
}
// Compile actual device ownership entrypoints without opening hardware in tests.
export fn audio_compile_playback(rate: u32, channels: u32) ?*n.PlaybackDevice {
    const value = n.PlaybackDevice.create(a, rate, channels, 500, 0) catch return null;
    value.start() catch {
        value.destroy();
        return null;
    };
    value.setGain(false, &.{65535});
    value.stop();
    value.destroy();
    return null;
}
export fn audio_compile_capture(rate: u32, channels: u32) ?*n.CaptureDevice {
    const value = n.CaptureDevice.create(a, rate, channels, 500) catch return null;
    value.start() catch {
        value.destroy();
        return null;
    };
    value.stop();
    value.destroy();
    return null;
}
