//! Apple calls only at the C boundary; Zig owns conversion chunking, bounds,
//! timestamps, fixed queues and diagnostics. Converter.capture has one serial
//! caller (one Core Audio tap). Drain/diagnostics may run concurrently. Join the
//! callback before destroying the owner; Device.stop supplies that join.
const std = @import("std");
const sync = @import("sync.zig");
const ring = @import("audio_ring.zig");
const buffer = @import("audio_buffer.zig");
extern "c" fn mach_absolute_time() u64;
pub const Format = extern struct { sample_rate: f64, channels: u32, bytes_per_frame: u32, interleaved: u32, common_format: u32 };
pub const BufferInfo = extern struct { frames: u32, buffers: u32 };
pub const Buffer = extern struct { data: ?[*]u8, bytes: u32, channels: u32 };
extern fn spice_zig_audio_format_info(*anyopaque, *Format) c_int;
extern fn spice_zig_audio_buffer_info(*anyopaque, *BufferInfo) c_int;
extern fn spice_zig_audio_buffer_at(*anyopaque, u32, *Buffer) c_int;
extern fn spice_zig_audio_converter_create(*anyopaque, u32, u32, u32, u32) ?*anyopaque;
extern fn spice_zig_audio_converter_destroy(*anyopaque) void;
extern fn spice_zig_audio_converter_matches(*anyopaque, *anyopaque) c_int;
extern fn spice_zig_audio_converter_input(*anyopaque, u32) ?*anyopaque;
extern fn spice_zig_audio_converter_output(*anyopaque) ?*anyopaque;
extern fn spice_zig_audio_convert(*anyopaque) c_int;
extern fn spice_zig_audio_playback_create(u32, u32, *const fn (*anyopaque, u32, *anyopaque) callconv(.c) void, *anyopaque) ?*anyopaque;
extern fn spice_zig_audio_playback_start(*anyopaque) c_int;
extern fn spice_zig_audio_playback_gain(*anyopaque, f32) void;
extern fn spice_zig_audio_capture_create(*const fn (*anyopaque, *anyopaque) callconv(.c) void, *anyopaque) ?*anyopaque;
extern fn spice_zig_audio_capture_format(*anyopaque) ?*anyopaque;
extern fn spice_zig_audio_capture_start(*anyopaque) c_int;
extern fn spice_zig_audio_device_stop(*anyopaque) void;
extern fn spice_zig_audio_device_destroy(*anyopaque) void;
extern fn spice_zig_audio_list_count(*anyopaque) u32;
extern fn spice_zig_audio_list_at(*anyopaque, u32, *Buffer) c_int;
pub const Diagnostics = struct { input_callbacks: u64 = 0, input_frames: u64 = 0, split_callbacks: u64 = 0, conversion_passes: u64 = 0, conversion_failures: u64 = 0, converted_frames: u64 = 0 };
pub const Converter = struct {
    native: *anyopaque,
    input: Format,
    maximum_input_frames: u32,
    output_bytes_per_frame: u32,
    queue: buffer.Capture,
    mutex: sync.Mutex = .{},
    stats: Diagnostics = .{},
    pub fn init(allocator: std.mem.Allocator, input_format: *anyopaque, rate: u32, channels: u32, maximum_frames: u32, capacity: ring.Capacity) !Converter {
        if (channels == 0 or channels > 8 or rate < 8000 or rate > 192000 or maximum_frames == 0) return error.InvalidAudioConfiguration;
        var format: Format = undefined;
        if (spice_zig_audio_format_info(input_format, &format) != 0) return error.InvalidAudioConfiguration;
        if (!std.math.isFinite(format.sample_rate) or format.sample_rate <= 0 or format.bytes_per_frame == 0 or format.channels == 0) return error.InvalidAudioConfiguration;
        const ratio = @as(f64, @floatFromInt(rate)) / format.sample_rate;
        const estimate = @as(f64, @floatFromInt(maximum_frames)) * ratio;
        if (!std.math.isFinite(estimate) or estimate < 0 or estimate >= @as(f64, @floatFromInt(std.math.maxInt(u32))) - 8) return error.InvalidAudioConfiguration;
        const output_frames: @TypeOf(maximum_frames) = @as(u32, @intFromFloat(@ceil(estimate))) + 8;
        const input_banks: usize = if (format.interleaved != 0) 1 else format.channels;
        if (@as(u128, maximum_frames) * format.bytes_per_frame * input_banks > ring.maximum_payload or @as(u64, output_frames) * channels * 2 > ring.maximum_payload) return error.InvalidAudioCapacity;
        var queue = try buffer.Capture.init(allocator, capacity);
        errdefer queue.deinit();
        const native = spice_zig_audio_converter_create(input_format, rate, channels, maximum_frames, output_frames) orelse return error.AudioConverterUnavailable;
        return .{ .native = native, .input = format, .maximum_input_frames = maximum_frames, .output_bytes_per_frame = channels * 2, .queue = queue };
    }
    pub fn deinit(self: *Converter) void {
        spice_zig_audio_converter_destroy(self.native);
        self.queue.deinit();
        self.mutex.deinit();
    }
    pub fn chunkTimestamp(base: u32, offset: u32, rate: f64) u32 {
        if (!std.math.isFinite(rate) or rate <= 0) return base;
        const ms = @floor(@as(f64, @floatFromInt(offset)) * 1000 / rate);
        // f64 rounds UInt64.max to 2^64; reject that nonrepresentable endpoint.
        if (!std.math.isFinite(ms) or ms < 0 or ms >= 18446744073709551616.0) return base;
        return base +% @as(u32, @truncate(@as(u64, @intFromFloat(ms))));
    }
    fn failure(self: *Converter, value: buffer.CaptureFailure) void {
        self.mutex.lock();
        self.stats.conversion_failures +|= 1;
        self.mutex.unlock();
        self.queue.fail(value);
    }
    pub fn capture(self: *Converter, input: *anyopaque, timestamp: u32) void {
        var info: BufferInfo = undefined;
        if (spice_zig_audio_buffer_info(input, &info) != 0) {
            self.failure(.invalid_input_storage);
            return;
        }
        self.mutex.lock();
        self.stats.input_callbacks +|= 1;
        self.stats.input_frames +|= info.frames;
        if (info.frames > self.maximum_input_frames) self.stats.split_callbacks +|= 1;
        self.mutex.unlock();
        if (info.frames == 0) return;
        if (spice_zig_audio_converter_matches(self.native, input) == 0) {
            self.failure(.input_format_changed);
            return;
        }
        const chunk = spice_zig_audio_converter_input(self.native, self.maximum_input_frames) orelse {
            self.failure(.invalid_input_storage);
            return;
        };
        var chunk_info: BufferInfo = undefined;
        if (spice_zig_audio_buffer_info(chunk, &chunk_info) != 0 or info.buffers != chunk_info.buffers or info.buffers == 0) {
            self.failure(.invalid_input_storage);
            return;
        }
        const required = @as(u64, info.frames) * self.input.bytes_per_frame;
        for (0..info.buffers) |index| {
            var source: Buffer = undefined;
            if (spice_zig_audio_buffer_at(input, @intCast(index), &source) != 0 or source.data == null or required > source.bytes) {
                self.failure(.invalid_input_storage);
                return;
            }
        }
        var offset: u32 = 0;
        while (offset < info.frames) {
            const count = @min(self.maximum_input_frames, info.frames - offset);
            const destination = spice_zig_audio_converter_input(self.native, count) orelse {
                self.failure(.invalid_input_storage);
                return;
            };
            const byte_offset = @as(usize, offset) * self.input.bytes_per_frame;
            const bytes = @as(usize, count) * self.input.bytes_per_frame;
            for (0..info.buffers) |index| {
                var source: Buffer = undefined;
                var target: Buffer = undefined;
                if (spice_zig_audio_buffer_at(input, @intCast(index), &source) != 0 or spice_zig_audio_buffer_at(destination, @intCast(index), &target) != 0 or source.data == null or target.data == null or byte_offset + bytes > source.bytes or bytes > target.bytes) {
                    self.failure(.invalid_input_storage);
                    return;
                }
                @memcpy(target.data.?[0..bytes], source.data.?[byte_offset..][0..bytes]);
            }
            if (spice_zig_audio_convert(self.native) != 0) {
                self.failure(.converter);
                return;
            }
            const output = spice_zig_audio_converter_output(self.native) orelse {
                self.failure(.invalid_output_storage);
                return;
            };
            var output_info: BufferInfo = undefined;
            if (spice_zig_audio_buffer_info(output, &output_info) != 0) {
                self.failure(.invalid_output_storage);
                return;
            }
            self.mutex.lock();
            self.stats.conversion_passes +|= 1;
            self.stats.converted_frames +|= output_info.frames;
            self.mutex.unlock();
            if (output_info.frames > 0) {
                const size = @as(usize, output_info.frames) * self.output_bytes_per_frame;
                var pcm: Buffer = undefined;
                if (output_info.buffers != 1 or spice_zig_audio_buffer_at(output, 0, &pcm) != 0 or pcm.data == null or size > pcm.bytes) {
                    self.failure(.invalid_output_storage);
                    return;
                }
                _ = self.queue.queue.enqueue(chunkTimestamp(timestamp, offset, self.input.sample_rate), pcm.data.?[0..size]);
            }
            offset += count;
        }
    }
    pub fn diagnostics(self: *Converter) Diagnostics {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }
};
pub const PlaybackDevice = struct {
    allocator: std.mem.Allocator,
    native: *anyopaque,
    playback: buffer.Playback,
    /// Creates a real device graph. Playback begins only at start(). Host calls
    /// enqueue/configuration/stop serially; the render callback is concurrent.
    pub fn create(allocator: std.mem.Allocator, rate: u32, channels: u32, maximum_ms: u32, minimum_ms: u32) !*PlaybackDevice {
        if (rate < 8000 or rate > 192000 or channels == 0 or channels > 8) return error.InvalidAudioConfiguration;
        const capacity = try ring.Capacity.pcm(rate, channels, maximum_ms);
        const self = try allocator.create(PlaybackDevice);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .native = undefined, .playback = try buffer.Playback.init(allocator, capacity, channels * 2, rate, minimum_ms) };
        errdefer self.playback.deinit();
        self.native = spice_zig_audio_playback_create(rate, channels, render, self) orelse return error.AudioDeviceUnavailable;
        return self;
    }
    pub fn start(self: *PlaybackDevice) !void {
        if (spice_zig_audio_playback_start(self.native) != 0) return error.AudioDeviceStartFailed;
    }
    pub fn setGain(self: *PlaybackDevice, muted: bool, volume: []const u16) void {
        var sum: u64 = 0;
        for (volume) |v| sum += v;
        const gain: f32 = if (muted) 0 else if (volume.len == 0) 1 else @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(volume.len)) / 65535;
        spice_zig_audio_playback_gain(self.native, std.math.clamp(gain, 0, 1));
    }
    pub fn stop(self: *PlaybackDevice) void {
        self.playback.close();
        spice_zig_audio_device_stop(self.native);
    }
    pub fn destroy(self: *PlaybackDevice) void {
        self.stop();
        spice_zig_audio_device_destroy(self.native);
        self.playback.deinit();
        self.allocator.destroy(self);
    }
    fn render(raw: *anyopaque, frames: u32, list: *anyopaque) callconv(.c) void {
        const self: *PlaybackDevice = @ptrCast(@alignCast(raw));
        renderList(&self.playback, frames, list);
    }
};
/// Shared production/offline seam: silence secondary or undersized buffers,
/// consume PCM only when the first destination holds all requested frames.
pub fn renderList(playback: *buffer.Playback, frames: u32, list: *anyopaque) void {
    const requested = @as(u64, frames) * playback.bytes_per_frame;
    if (requested == 0) return;
    for (0..spice_zig_audio_list_count(list)) |index| {
        var item: Buffer = undefined;
        if (spice_zig_audio_list_at(list, @intCast(index), &item) != 0) continue;
        const pointer = item.data orelse continue;
        const size: @TypeOf(playback.bytes_per_frame) = @intCast(@min(requested, item.bytes));
        if (index == 0 and size == requested) {
            _ = playback.render(pointer[0..size]);
        } else @memset(pointer[0..size], 0);
    }
}
pub const CaptureDevice = struct {
    allocator: std.mem.Allocator,
    native: *anyopaque,
    converter: Converter,
    timebase: std.c.mach_timebase_info_data,
    pub fn create(allocator: std.mem.Allocator, rate: u32, channels: u32, maximum_ms: u32) !*CaptureDevice {
        if (rate < 8000 or rate > 192000 or channels == 0 or channels > 8) return error.InvalidAudioConfiguration;
        const capacity = try ring.Capacity.pcm(rate, channels, maximum_ms);
        var timebase: std.c.mach_timebase_info_data = undefined;
        if (std.c.mach_timebase_info(&timebase) != 0 or timebase.denom == 0) return error.ClockUnavailable;
        const self = try allocator.create(CaptureDevice);
        errdefer allocator.destroy(self);
        const native = spice_zig_audio_capture_create(capture, self) orelse return error.AudioDeviceUnavailable;
        errdefer spice_zig_audio_device_destroy(native);
        const format = spice_zig_audio_capture_format(native) orelse return error.AudioDeviceUnavailable;
        self.* = .{ .allocator = allocator, .native = native, .converter = try Converter.init(allocator, format, rate, channels, 1024, capacity), .timebase = timebase };
        return self;
    }
    pub fn start(self: *CaptureDevice) !void {
        if (spice_zig_audio_capture_start(self.native) != 0) return error.AudioDeviceStartFailed;
    }
    pub fn stop(self: *CaptureDevice) void {
        spice_zig_audio_device_stop(self.native);
        self.converter.queue.close();
    }
    pub fn destroy(self: *CaptureDevice) void {
        self.stop();
        spice_zig_audio_device_destroy(self.native);
        self.converter.deinit();
        self.allocator.destroy(self);
    }
    fn capture(raw: *anyopaque, pcm: *anyopaque) callconv(.c) void {
        const self: *CaptureDevice = @ptrCast(@alignCast(raw));
        self.converter.capture(pcm, @truncate(@as(u128, mach_absolute_time()) * self.timebase.numer / self.timebase.denom / 1_000_000));
    }
};
