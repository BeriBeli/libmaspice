// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2009 Red Hat, Inc.
// Zig adaptation of spice-common's QUIC encoder/decoder.
// No C codec implementation is called or linked. See README.md.
const std = @import("std");
const random = @import("random.zig").values;
const Allocator = std.mem.Allocator;
pub const DecodeError = error{ Truncated, InvalidHeader, UnsupportedType, DimensionMismatch, LimitExceeded, MalformedCode, InvalidRun, InvalidState, InvalidStride, OutputExhausted, LinesExhausted } || Allocator.Error;

pub const MoreInput = *const fn (?*anyopaque, *?[*]const u8, c_int) callconv(.c) c_int;

const Reader = struct {
    more: ?MoreInput = null,
    user: ?*anyopaque = null,
    rows: c_int = 0,
    input: []const u8,
    // The next unread bit is at the top. Successful consumption preserves at
    // least 32 valid lookahead bits, refilling a little-endian word only when
    // necessary. decode validates the initial length/alignment before init.
    buffer: u64,
    available: u7 = 64,

    fn init(input: []const u8) Reader {
        return .{ .input = input[8..], .buffer = (@as(u64, std.mem.readInt(u32, input[0..4], .little)) << 32) |
            std.mem.readInt(u32, input[4..8], .little) };
    }

    fn stream(input: []const u8, more: ?MoreInput, user: ?*anyopaque) DecodeError!Reader {
        var result: Reader = .{ .input = input, .buffer = 0, .more = more, .user = user };
        const high = try result.word();
        result.buffer = (@as(u64, high) << 32) | try result.word();
        return result;
    }

    fn word(self: *Reader) DecodeError!u32 {
        if (self.input.len == 0) {
            const callback = self.more orelse return error.Truncated;
            var pointer: ?[*]const u8 = null;
            const words = callback(self.user, &pointer, self.rows);
            if (words <= 0 or pointer == null) return error.Truncated;
            self.input = pointer.?[0 .. @as(usize, @intCast(words)) * 4];
        }
        if (self.input.len < 4) return error.Truncated;
        const value = std.mem.readInt(u32, self.input[0..4], .little);
        self.input = self.input[4..];
        return value;
    }

    inline fn peek(self: Reader) u32 {
        return @truncate(self.buffer >> 32);
    }

    inline fn consume(self: *Reader, count: usize) DecodeError!void {
        if (count == 0 or count > 32) return error.Truncated;
        self.buffer <<= @intCast(count);
        self.available -= @intCast(count);
        if (self.available < 32) {
            self.buffer |= @as(u64, try self.word()) << @intCast(32 - self.available);
            self.available += 32;
        }
    }

    fn header(self: *Reader) DecodeError!u32 {
        const value = self.peek();
        try self.consume(32);
        return value;
    }
};

fn Family(comptime depth: u5) type {
    return struct {
        const Self = @This();
        const mask: u32 = (@as(u32, 1) << depth) - 1;
        regular: [depth]u32,
        suffix: [depth]u5,
        length: [depth]u5,
        prefix_mask: [depth]u32,
        code_lengths: [1 << depth][depth]u8,

        fn init() Self {
            @setEvalBranchQuota(100_000);
            var result: Self = undefined;
            for (0..depth) |code| {
                const prefix: u5 = @intCast(@min(26 - depth, (@as(u32, 1) << @intCast(depth - code)) - 1));
                const regular = @as(u32, prefix) << @intCast(code);
                const alternatives = (1 << depth) - regular;
                const suffix: u5 = @intCast(if (alternatives == 1) 0 else 32 - @clz(alternatives - 1));
                result.regular[code] = regular;
                result.suffix[code] = suffix;
                result.length[code] = prefix + suffix;
                result.prefix_mask[code] = std.math.maxInt(u32) >> prefix;
                for (0..(1 << depth)) |value| {
                    result.code_lengths[value][code] = @intCast(if (value < regular)
                        (value >> @intCast(code)) + code + 1
                    else
                        prefix + suffix);
                }
            }
            return result;
        }

        inline fn residual(self: *const Self, code: usize, reader: *Reader) DecodeError!u8 {
            // There are only depth legal parameters. Specializing them makes
            // the masks and shifts constant without a prefix lookup table.
            return switch (code) {
                inline 0...depth - 1 => |parameter| self.residualCode(parameter, reader),
                else => error.MalformedCode,
            };
        }

        inline fn residualCode(self: *const Self, comptime code: usize, reader: *Reader) DecodeError!u8 {
            const bits = reader.peek();
            // At the maximum Rice parameter, every codeword has exactly depth
            // bits. Decode it directly instead of finding a unary prefix.
            if (code == depth - 1) {
                const value = (bits >> (32 - @as(u6, depth))) ^ (@as(u32, 1) << (depth - 1));
                try reader.consume(depth);
                return @intCast(value);
            }
            var length: u5 = undefined;
            var value: u32 = undefined;
            if (bits > self.prefix_mask[code]) {
                const zeros = @clz(bits);
                length = @intCast(zeros + 1 + code);
                value = (@as(u32, zeros) << @intCast(code)) |
                    ((bits >> @as(u5, @intCast(32 - @as(u6, length)))) & ((@as(u32, 1) << @intCast(code)) - 1));
            } else {
                length = self.length[code];
                value = self.regular[code] +
                    ((bits >> @as(u5, @intCast(32 - @as(u6, length)))) & ((@as(u32, 1) << self.suffix[code]) - 1));
            }
            if (value > mask) return error.MalformedCode;
            try reader.consume(length);
            return @intCast(value);
        }

        fn unmap(value: u8) u32 {
            return if (value & 1 == 0) value >> 1 else mask - (value >> 1);
        }
    };
}

// Each normalized row fits the upstream malloc(int) ABI even at its maximum
// legal width. Separate allocations avoid an accidental INT_MAX/8 axis cap.
const RowPair = struct {
    previous: []u8,
    current: []u8,

    fn init(allocator: Allocator, width: usize) Allocator.Error!RowPair {
        const previous = try allocator.alloc(u8, width * 4);
        errdefer allocator.free(previous);
        const current = try allocator.alloc(u8, width * 4);
        @memset(previous, 0);
        @memset(current, 0);
        return .{ .previous = previous, .current = current };
    }
    fn deinit(self: RowPair, allocator: Allocator) void {
        allocator.free(self.previous);
        allocator.free(self.current);
    }
    fn advance(self: *RowPair) void {
        std.mem.swap([]u8, &self.previous, &self.current);
    }
};

inline fn readPixel(buffer: anytype, index: usize) u8 {
    if (@TypeOf(buffer) == RowPair) {
        return if (index < buffer.previous.len) buffer.previous[index] else buffer.current[index - buffer.previous.len];
    }
    return buffer[index];
}

inline fn writePixel(buffer: anytype, index: usize, value: u8) void {
    if (@TypeOf(buffer) == RowPair) {
        buffer.current[index - buffer.previous.len] = value;
    } else {
        buffer[index] = value;
    }
}

fn Group(comptime depth: u5, comptime offsets: []const usize) type {
    return struct {
        const Self = @This();
        const Coding = Family(depth);
        const family = Coding.init();
        const triggers = [_]u32{ 110, 550, 900, 800, 550, 400, 350 };
        const run_bits = [_]u5{ 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
        residuals: []u8,
        stride: usize,
        best: [offsets.len][depth]u8 = @splat(@splat(depth - 1)),
        counters: [offsets.len][depth][depth]u32 = @splat(@splat(@splat(0))),
        wait: usize = 0,
        seed: u8 = 255,
        window: u3 = 0,
        remaining: usize = 2048,
        run_state: u5 = 0,

        fn init(allocator: Allocator, width: usize) !Self {
            const residuals = try allocator.alloc(u8, (width + 1) * offsets.len);
            @memset(residuals, 0);
            return .{ .residuals = residuals, .stride = width + 1 };
        }

        fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.residuals);
        }

        fn bucket(value: u8) usize {
            return @min(15 - @clz(@as(u16, value) + 1), depth - 1);
        }

        fn nextWait(self: *Self) usize {
            self.seed +%= 1;
            return random[self.seed] & ((@as(u32, 1) << self.window) - 1);
        }

        fn update(self: *Self, x: usize) void {
            inline for (0..offsets.len) |c| {
                const base = c * self.stride;
                const b = bucket(self.residuals[base + x]);
                const value = self.residuals[base + x + 1];
                var best_length: u32 = std.math.maxInt(u32);
                var best_code: u8 = depth - 1;
                inline for (0..depth) |reverse| {
                    const code = depth - 1 - reverse;
                    self.counters[c][b][code] += family.code_lengths[value][code];
                    if (self.counters[c][b][code] < best_length) {
                        best_length = self.counters[c][b][code];
                        best_code = code;
                    }
                }
                self.best[c][b] = best_code;
                if (best_length > triggers[self.window]) {
                    inline for (0..depth) |code| self.counters[c][b][code] >>= 1;
                }
            }
        }

        inline fn pixel(self: *Self, comptime first_row: bool, comptime first_column: bool, x: usize, row: usize, width: usize, reader: *Reader, output: anytype) DecodeError!void {
            inline for (offsets, 0..) |offset, c| {
                const base = c * self.stride;
                const code = self.best[c][bucket(self.residuals[base + x])];
                const value = try family.residual(code, reader);
                self.residuals[base + x + 1] = value;
                const index = (row * width + x) * 4 + offset;
                const left: u32 = if (first_column) 0 else readPixel(output, index - 4);
                const above: u32 = if (first_row) 0 else readPixel(output, index - width * 4);
                const predicted = if (first_column) above else if (first_row) left else (left + above) >> 1;
                writePixel(output, index, @intCast((predicted + Coding.unmap(value)) & Coding.mask));
            }
        }

        inline fn same(a: usize, b: usize, output: anytype) bool {
            inline for (offsets) |offset| {
                if (readPixel(output, a + offset) != readPixel(output, b + offset)) return false;
            }
            return true;
        }

        fn run(self: *Self, reader: *Reader, maximum: usize) DecodeError!usize {
            var length: usize = 0;
            while (reader.peek() & 0x8000_0000 != 0) {
                length += @as(usize, 1) << run_bits[self.run_state];
                if (length > maximum) return error.InvalidRun;
                try reader.consume(1);
                if (self.run_state < 31) self.run_state += 1;
            }
            try reader.consume(1);
            const bits = run_bits[self.run_state];
            if (bits > 0) {
                length += reader.peek() >> @as(u5, @intCast(32 - @as(u6, bits)));
                try reader.consume(bits);
            }
            if (length > maximum) return error.InvalidRun;
            if (self.run_state > 0) self.run_state -= 1;
            return length;
        }

        fn segment(self: *Self, comptime first_row: bool, row: usize, width: usize, start: usize, end: usize, source: *Reader, output: anytype) DecodeError!void {
            // Keep input state local across output/model writes. It cannot
            // alias either allocation, so the hot loop can retain it in registers.
            var local_reader = source.*;
            defer source.* = local_reader;
            const reader = &local_reader;
            var x = start;
            var run_index: usize = 0;
            if (x == 0) {
                try self.pixel(first_row, true, x, row, width, reader, output);
                if (self.wait > 0) self.wait -= 1 else {
                    self.wait = self.nextWait();
                    self.update(0);
                }
                x += 1;
            }
            var stop = x + self.wait;
            while (x < end) {
                const index = (row * width + x) * 4;
                if (!first_row and x > 2 and run_index != x and
                    same(index - width * 4 - 4, index - width * 4, output) and
                    same(index - 4, index - 8, output))
                {
                    self.wait = stop - x;
                    run_index = x;
                    const length = try self.run(reader, end - x);
                    for (x..x + length) |p| {
                        inline for (offsets) |offset| writePixel(output, (row * width + p) * 4 + offset, readPixel(output, index - 4 + offset));
                    }
                    x += length;
                    if (x == end) return;
                    stop = x + self.wait;
                    continue;
                }
                try self.pixel(first_row, false, x, row, width, reader, output);
                if (x == stop) {
                    self.update(x);
                    stop = x + 1 + self.nextWait();
                }
                x += 1;
            }
            self.wait = stop - end;
        }

        inline fn encodePixel(self: *Self, comptime first_row: bool, comptime first_column: bool, x: usize, width: usize, writer: *Writer, pixels: RowPair) DecodeError!void {
            inline for (offsets, 0..) |offset, c| {
                const base = c * self.stride;
                const code = self.best[c][bucket(self.residuals[base + x])];
                const index = (width + x) * 4 + offset;
                const left: u32 = if (first_column) 0 else readPixel(pixels, index - 4);
                const above: u32 = if (first_row) 0 else readPixel(pixels, index - width * 4);
                const predicted = if (first_column) above else if (first_row) left else (left + above) >> 1;
                const delta = (@as(u32, readPixel(pixels, index)) -% predicted) & Coding.mask;
                const value: u8 = @intCast(if (delta <= Coding.mask / 2) delta * 2 else (Coding.mask - delta) * 2 + 1);
                self.residuals[base + x + 1] = value;
                if (value < family.regular[code]) {
                    const parameter: u5 = @intCast(code);
                    try writer.bits((@as(u32, 1) << parameter) | (value & ((@as(u32, 1) << parameter) - 1)), @intCast(family.code_lengths[value][code]));
                } else {
                    try writer.bits(value - family.regular[code], family.length[code]);
                }
            }
        }

        fn encodeRun(self: *Self, writer: *Writer, size: usize) DecodeError!void {
            var length = size;
            while (length >= @as(usize, 1) << run_bits[self.run_state]) {
                length -= @as(usize, 1) << run_bits[self.run_state];
                try writer.bits(1, 1);
                if (self.run_state < 31) self.run_state += 1;
            }
            try writer.bits(@intCast(length), @as(u6, run_bits[self.run_state]) + 1);
            if (self.run_state > 0) self.run_state -= 1;
        }

        fn encodeSegment(self: *Self, comptime first_row: bool, width: usize, start: usize, end: usize, writer: *Writer, pixels: RowPair) DecodeError!void {
            var x = start;
            var run_index: usize = 0;
            if (x == 0) {
                try self.encodePixel(first_row, true, x, width, writer, pixels);
                if (self.wait > 0) self.wait -= 1 else {
                    self.wait = self.nextWait();
                    self.update(0);
                }
                x += 1;
            }
            var stop = x + self.wait;
            while (x < end) {
                const index = (width + x) * 4;
                if (!first_row and x > 2 and run_index != x and
                    same(index - width * 4 - 4, index - width * 4, pixels) and
                    same(index - 4, index - 8, pixels))
                {
                    self.wait = stop - x;
                    run_index = x;
                    while (x < end and same((width + x) * 4, index - 4, pixels)) : (x += 1) {}
                    try self.encodeRun(writer, x - run_index);
                    if (x == end) return;
                    stop = x + self.wait;
                    continue;
                }
                try self.encodePixel(first_row, false, x, width, writer, pixels);
                if (x == stop) {
                    self.update(x);
                    stop = x + 1 + self.nextWait();
                }
                x += 1;
            }
            self.wait = stop - end;
        }

        fn encodeRow(self: *Self, comptime first_row: bool, width: usize, writer: *Writer, pixels: RowPair) DecodeError!void {
            inline for (0..offsets.len) |c| self.residuals[c * self.stride] = self.residuals[c * self.stride + 1];
            var start: usize = 0;
            while (self.window < 6 and self.remaining <= width - start) {
                if (self.remaining > 0) {
                    try self.encodeSegment(first_row, width, start, start + self.remaining, writer, pixels);
                    start += self.remaining;
                }
                self.window += 1;
                self.remaining = 2048;
            }
            if (start < width) {
                try self.encodeSegment(first_row, width, start, width, writer, pixels);
                if (self.window < 6) self.remaining -= width - start;
            }
        }

        fn decodeRow(self: *Self, comptime first_row: bool, y: usize, width: usize, reader: *Reader, output: anytype) DecodeError!void {
            inline for (0..offsets.len) |c| self.residuals[c * self.stride] = self.residuals[c * self.stride + 1];
            var start: usize = 0;
            while (self.window < 6 and self.remaining <= width - start) {
                if (self.remaining > 0) {
                    try self.segment(first_row, y, width, start, start + self.remaining, reader, output);
                    start += self.remaining;
                }
                self.window += 1;
                self.remaining = 2048;
            }
            if (start < width) {
                try self.segment(first_row, y, width, start, width, reader, output);
                if (self.window < 6) self.remaining -= width - start;
            }
        }
    };
}

fn image(comptime depth: u5, comptime gray: bool, comptime alpha: bool, allocator: Allocator, reader: *Reader, width: usize, height: usize, output: []u8) DecodeError!void {
    var color = try Group(depth, if (gray) &.{0} else &.{ 2, 1, 0 }).init(allocator, width);
    defer color.deinit(allocator);
    var opacity: if (alpha) Group(8, &.{3}) else void = if (alpha) try Group(8, &.{3}).init(allocator, width) else {};
    defer if (alpha) opacity.deinit(allocator);
    @memset(output, 0);
    try color.decodeRow(true, 0, width, reader, output);
    if (alpha) try opacity.decodeRow(true, 0, width, reader, output);
    reader.rows = 1;
    for (1..height) |y| {
        try color.decodeRow(false, y, width, reader, output);
        if (alpha) try opacity.decodeRow(false, y, width, reader, output);
        reader.rows += 1;
    }
    if (gray or depth == 5) {
        var i: usize = 0;
        while (i < output.len) : (i += 4) {
            if (gray) {
                output[i + 1] = output[i];
                output[i + 2] = output[i];
            } else {
                inline for (0..3) |c| output[i + c] = (output[i + c] << 3) | (output[i + c] >> 2);
            }
        }
    }
}

fn decode(allocator: Allocator, input: []const u8, width: usize, height: usize, output: []u8) DecodeError!void {
    if (width == 0 or height == 0 or width > 16384 or height > 16384 or input.len > 64 * 1024 * 1024)
        return error.LimitExceeded;
    const bytes = width * height * 4; // dimensions above make multiplication safe on arm64
    if (bytes > 256 * 1024 * 1024 or output.len != bytes) return error.LimitExceeded;
    if (input.len < 24 or input.len % 4 != 0) return error.Truncated;
    var reader = Reader.init(input);
    if (try reader.header() != 0x4349_5551 or try reader.header() != 0) return error.InvalidHeader;
    const kind = try reader.header();
    if (kind < 1 or kind > 5) return error.UnsupportedType;
    const encoded_width = try reader.header();
    const encoded_height = try reader.header();
    if (encoded_width != width or encoded_height != height) return error.DimensionMismatch;
    switch (kind) {
        1 => try image(8, true, false, allocator, &reader, width, height, output),
        2 => try image(5, false, false, allocator, &reader, width, height, output),
        3, 4 => try image(8, false, false, allocator, &reader, width, height, output),
        5 => try image(8, false, true, allocator, &reader, width, height, output),
        else => unreachable,
    }
}

/// C ABI for the experimental harness. Buffers must be valid, non-overlapping
/// regions of the stated lengths. Output is unspecified on error; no state or
/// allocation survives the call. All errors are returned, never longjmp'd.
pub fn zig_quic_decode(input: [*]const u8, input_len: usize, width: usize, height: usize, output: [*]u8, output_len: usize) callconv(.c) c_int {
    decode(std.heap.page_allocator, input[0..input_len], width, height, output[0..output_len]) catch |err| {
        return switch (err) {
            error.Truncated => 2,
            error.UnsupportedType => 3,
            error.DimensionMismatch => 4,
            error.LimitExceeded => 5,
            error.OutOfMemory => 6,
            else => 1,
        };
    };
    return 0;
}

fn testImage(kind: u32) [28]u8 {
    var input: [28]u8 = undefined;
    // Initial Rice code 7 encodes a zero residual as 10000000. A 1x1
    // gray/RGBA image uses one/four such codes, followed by word padding.
    const words = [_]u32{ 0x4349_5551, 0, kind, 1, 1, if (kind == 2) 0x8420_0000 else 0x8080_8080, 0 };
    for (words, 0..) |value, i| std.mem.writeInt(u32, input[i * 4 ..][0..4], value, .little);
    return input;
}

fn allocationTrial(allocator: Allocator, kind: u32) !void {
    const input = testImage(kind);
    var output: [4]u8 = undefined;
    try decode(allocator, &input, 1, 1, &output);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &output);
}

test "all model allocations clean up on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationTrial, .{@as(u32, 1)});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationTrial, .{@as(u32, 5)});
}

test "truncated streams and invalid output sizes release owned models" {
    const input = testImage(5);
    var output: [4]u8 = undefined;
    for (0..input.len) |length| {
        try std.testing.expectError(error.Truncated, decode(std.testing.allocator, input[0..length], 1, 1, &output));
    }
    try std.testing.expectError(error.LimitExceeded, decode(std.testing.allocator, &input, 1, 1, output[0..3]));
    try std.testing.expectError(error.LimitExceeded, decode(std.testing.allocator, &input, std.math.maxInt(usize), 1, &output));
    try std.testing.expectError(error.LimitExceeded, decode(std.testing.allocator, &input, 1, 16385, &output));
    var malformed = input;
    std.mem.writeInt(u32, malformed[12..16], 2, .little);
    @memset(malformed[20..], 0);
    var wider_output: [8]u8 = undefined;
    try std.testing.expectError(error.Truncated, decode(std.testing.allocator, &malformed, 2, 1, &wider_output));
}

test "bit reservoir preserves lookahead across every word boundary" {
    var input: [64]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = @truncate(i * 73 + 19);
    // An independent, bit-at-a-time oracle for the word-little-endian,
    // bit-most-significant-first stream. Sweep all consumption widths.
    for (0..32) |phase| {
        var reader = Reader.init(&input);
        var position: usize = 0;
        var step = phase;
        while (true) {
            var expected: u32 = 0;
            for (position..position + 32) |bit| {
                const byte = input[(bit / 32) * 4 + 3 - (bit % 32) / 8];
                expected = (expected << 1) | ((byte >> @as(u3, @intCast(7 - bit % 8))) & 1);
            }
            try std.testing.expectEqual(expected, reader.peek());
            const count = step % 32 + 1;
            if (position + count > input.len * 8 - 32) {
                try std.testing.expectError(error.Truncated, reader.consume(count));
                break;
            }
            try reader.consume(count);
            position += count;
            step += 1;
        }
    }
    var reader = Reader.init(&input);
    try std.testing.expectError(error.Truncated, reader.consume(0));
    try std.testing.expectError(error.Truncated, reader.consume(33));
}

// The complete API uses upstream's positive signed dimensions and pixel limit.
// Unlike the bounded experiment it has no 16384-axis or 64 MiB input cap.
pub const Metadata = extern struct { kind: c_int, width: c_int, height: c_int };
pub const Context = struct {
    allocator: Allocator,
    reader: ?Reader = null,
    metadata: Metadata = .{ .kind = 0, .width = 0, .height = 0 },

    pub fn begin(self: *Context, input: []const u8, more: ?MoreInput, user: ?*anyopaque) DecodeError!Metadata {
        self.reader = null;
        if (input.len == 0 or input.len % 4 != 0) return error.Truncated;
        var reader = try Reader.stream(input, more, user);
        if (try reader.header() != 0x4349_5551 or try reader.header() != 0) return error.InvalidHeader;
        const kind = try reader.header();
        const width = try reader.header();
        const height = try reader.header();
        if (kind < 1 or kind > 5) return error.UnsupportedType;
        if (width == 0 or height == 0 or width > std.math.maxInt(c_int) or height > std.math.maxInt(c_int)) return error.InvalidHeader;
        if (@as(u64, width) * height > 512 * 1024 * 1024 - 1) return error.LimitExceeded;
        self.metadata = .{ .kind = @intCast(kind), .width = @intCast(width), .height = @intCast(height) };
        self.reader = reader;
        return self.metadata;
    }

    pub fn finish(self: *Context, kind: c_int, output: []u8, stride: i64) DecodeError!void {
        const source = self.metadata.kind;
        if (self.reader == null) return error.InvalidState;
        if (!compatible(source, kind)) return error.UnsupportedType;
        const width: usize = @intCast(self.metadata.width);
        const height: usize = @intCast(self.metadata.height);
        const pitch = try checkedLayout(width, height, kind, stride, output.len);
        var reader = self.reader.?;
        // A consumed or failed body requires a fresh begin. Invalid output
        // arguments above leave the header state available for a corrected call.
        self.reader = null;
        if (stride > 0 and pitch == width * 4 and (kind == 4 or kind == 5)) {
            const contiguous = output[0 .. pitch * height];
            return switch (source) {
                2 => image(5, false, false, self.allocator, &reader, width, height, contiguous),
                3, 4 => image(8, false, false, self.allocator, &reader, width, height, contiguous),
                5 => image(8, false, true, self.allocator, &reader, width, height, contiguous),
                else => unreachable, // compatibility checked above
            };
        }
        switch (source) {
            1 => try self.rows(8, true, false, &reader, kind, output, stride, pitch),
            2 => try self.rows(5, false, false, &reader, kind, output, stride, pitch),
            3, 4 => try self.rows(8, false, false, &reader, kind, output, stride, pitch),
            5 => try self.rows(8, false, true, &reader, kind, output, stride, pitch),
            else => unreachable,
        }
    }

    fn rows(self: *Context, comptime depth: u5, comptime gray: bool, comptime alpha: bool, reader: *Reader, kind: c_int, output: []u8, stride: i64, pitch: usize) DecodeError!void {
        const width: usize = @intCast(self.metadata.width);
        const height: usize = @intCast(self.metadata.height);
        var color = try Group(depth, if (gray) &.{0} else &.{ 2, 1, 0 }).init(self.allocator, width);
        defer color.deinit(self.allocator);
        var opacity: if (alpha) Group(8, &.{3}) else void = if (alpha) try Group(8, &.{3}).init(self.allocator, width) else {};
        defer if (alpha) opacity.deinit(self.allocator);
        var scratch = try RowPair.init(self.allocator, width);
        defer scratch.deinit(self.allocator);
        for (0..height) |y| {
            if (y == 0) {
                try color.decodeRow(true, 1, width, reader, scratch);
                if (alpha) try opacity.decodeRow(true, 1, width, reader, scratch);
            } else {
                try color.decodeRow(false, 1, width, reader, scratch);
                if (alpha) try opacity.decodeRow(false, 1, width, reader, scratch);
            }
            reader.rows += 1;
            const start = (if (stride < 0) height - 1 - y else y) * pitch;
            const row = output[start..][0 .. width * components(kind)];
            for (0..width) |x| {
                const pixel = scratch.current[x * 4 ..][0..4];
                switch (kind) {
                    1 => row[x] = pixel[0],
                    2 => std.mem.writeInt(u16, row[x * 2 ..][0..2], @as(u16, pixel[0]) | (@as(u16, pixel[1]) << 5) | (@as(u16, pixel[2]) << 10), .little),
                    3 => @memcpy(row[x * 3 ..][0..3], pixel[0..3]),
                    4, 5 => {
                        @memcpy(row[x * 4 ..][0..4], pixel);
                        if (depth == 5) inline for (0..3) |c| {
                            row[x * 4 + c] = (pixel[c] << 3) | (pixel[c] >> 2);
                        };
                    },
                    else => unreachable,
                }
            }
            scratch.advance();
        }
    }
};

fn compatible(source: c_int, target: c_int) bool {
    return switch (source) {
        1 => target == 1,
        2 => target == 2 or target == 4,
        3, 4 => target == 3 or target == 4,
        5 => target == 5,
        else => false,
    };
}

pub fn components(kind: c_int) usize {
    return switch (kind) {
        1 => 1,
        2 => 2,
        3 => 3,
        4, 5 => 4,
        else => 0,
    };
}

fn checkedLayout(width: usize, height: usize, kind: c_int, stride: i64, capacity: usize) DecodeError!usize {
    if (stride == std.math.minInt(i64)) return error.InvalidStride;
    const pitch: usize = @intCast(@abs(stride));
    const bytes = std.math.mul(usize, width, components(kind)) catch return error.LimitExceeded;
    if (pitch < bytes) return error.InvalidStride;
    const tail = std.math.mul(usize, height - 1, pitch) catch return error.LimitExceeded;
    const needed = std.math.add(usize, tail, bytes) catch return error.LimitExceeded;
    if (capacity < needed) return error.LimitExceeded;
    return pitch;
}

// Validation-only entry points, exported by experiment.zig.
pub fn zig_quic_context_create() callconv(.c) ?*Context {
    const context = std.heap.page_allocator.create(Context) catch return null;
    context.* = .{ .allocator = std.heap.page_allocator };
    return context;
}
pub fn zig_quic_context_destroy(context: ?*Context) callconv(.c) void {
    if (context) |value| std.heap.page_allocator.destroy(value);
}
pub fn zig_quic_begin(context: *Context, input: [*]const u8, size: usize, more: ?MoreInput, user: ?*anyopaque, metadata: *Metadata) callconv(.c) c_int {
    metadata.* = context.begin(input[0..size], more, user) catch return -1;
    return 0;
}
pub fn zig_quic_finish(context: *Context, kind: c_int, output: [*]u8, size: usize, stride: i64) callconv(.c) c_int {
    context.finish(kind, output[0..size], stride) catch return -1;
    return 0;
}

fn streamAllocationTrial(allocator: Allocator, kind: u32, target: c_int, stride: i64) !void {
    const input = testImage(kind);
    var context: Context = .{ .allocator = allocator };
    _ = try context.begin(&input, null, null);
    var output: [8]u8 = @splat(0xa5);
    try context.finish(target, &output, stride);
    const n = components(target);
    for (output[0..n]) |value| try std.testing.expectEqual(@as(u8, 0), value);
    for (output[n..]) |value| try std.testing.expectEqual(@as(u8, 0xa5), value);
}

test "streaming decode frees row and model storage at every allocation failure" {
    for (1..6) |kind| {
        for (1..6) |target| {
            if (compatible(@intCast(kind), @intCast(target))) {
                try std.testing.checkAllAllocationFailures(std.testing.allocator, streamAllocationTrial, .{ @as(u32, @intCast(kind)), @as(c_int, @intCast(target)), @as(i64, -8) });
            }
        }
    }
}

test "full decoder uses upstream header bounds and invalidates failed begin" {
    var context: Context = .{ .allocator = std.testing.allocator };
    var input = testImage(1);
    std.mem.writeInt(u32, input[12..16], 16385, .little);
    const metadata = try context.begin(&input, null, null);
    try std.testing.expectEqual(@as(c_int, 16385), metadata.width);
    std.mem.writeInt(u32, input[12..16], 512 * 1024 * 1024, .little);
    try std.testing.expectError(error.LimitExceeded, context.begin(&input, null, null));
    var output: [4]u8 = undefined;
    try std.testing.expectError(error.InvalidState, context.finish(1, &output, 4));
    std.mem.writeInt(u32, input[12..16], 0x80000000, .little);
    try std.testing.expectError(error.InvalidHeader, context.begin(&input, null, null));
}

pub const MoreOutput = *const fn (?*anyopaque, *?[*]u8, c_int) callconv(.c) c_int;
pub const MoreLines = *const fn (?*anyopaque, *?[*]const u8) callconv(.c) c_int;

pub const Writer = struct {
    output: []u8,
    more: ?MoreOutput = null,
    user: ?*anyopaque = null,
    rows: c_int = 0,
    word: u32 = 0,
    available: u6 = 32,
    count: usize = 0,

    fn write(self: *Writer) DecodeError!void {
        if (self.output.len == 0) {
            const callback = self.more orelse return error.OutputExhausted;
            var pointer: ?[*]u8 = null;
            const words = callback(self.user, &pointer, self.rows);
            if (words <= 0 or pointer == null) return error.OutputExhausted;
            self.output = pointer.?[0 .. @as(usize, @intCast(words)) * 4];
        }
        if (self.output.len < 4) return error.OutputExhausted;
        if (self.count == std.math.maxInt(c_int)) return error.LimitExceeded;
        std.mem.writeInt(u32, self.output[0..4], self.word, .little);
        self.output = self.output[4..];
        self.count += 1;
    }

    fn bits(self: *Writer, value: u32, length: u6) DecodeError!void {
        std.debug.assert(length > 0 and length < 32);
        std.debug.assert(value >> @as(u5, @intCast(length)) == 0);
        if (length <= self.available) {
            self.available -= length;
            self.word |= value << @intCast(self.available);
        } else {
            const delta = length - self.available;
            self.word |= value >> @intCast(delta);
            try self.write();
            self.available = 32 - delta;
            self.word = value << @intCast(self.available);
        }
    }

    fn header(self: *Writer, value: u32) DecodeError!void {
        try self.bits(value >> 16, 16);
        try self.bits(value & 0xffff, 16);
    }

    fn flush(self: *Writer) DecodeError!void {
        if (self.available > 0 and self.available != 32) try self.bits(0, self.available);
        try self.header(0);
        try self.bits(0, 1);
    }
};

pub const Lines = struct {
    pointer: ?[*]const u8,
    count: usize,
    stride: i64,
    more: ?MoreLines = null,
    user: ?*anyopaque = null,

    fn next(self: *Lines, bytes: usize) DecodeError![]const u8 {
        if (self.count == 0) {
            const callback = self.more orelse return error.LinesExhausted;
            const count = callback(self.user, &self.pointer);
            if (count <= 0) return error.LinesExhausted;
            self.count = @intCast(count);
        }
        const pointer = self.pointer orelse return error.LinesExhausted;
        self.count -= 1;
        if (self.count > 0) {
            const address = @intFromPtr(pointer);
            const next_address = if (self.stride < 0)
                std.math.sub(usize, address, @intCast(@abs(self.stride))) catch return error.InvalidStride
            else
                std.math.add(usize, address, @intCast(self.stride)) catch return error.InvalidStride;
            self.pointer = @ptrFromInt(next_address);
        }
        return pointer[0..bytes];
    }
};

fn encodeImage(comptime depth: u5, comptime gray: bool, comptime alpha: bool, allocator: Allocator, kind: c_int, width: usize, height: usize, lines: *Lines, writer: *Writer) DecodeError!void {
    var color = try Group(depth, if (gray) &.{0} else &.{ 2, 1, 0 }).init(allocator, width);
    defer color.deinit(allocator);
    var opacity: if (alpha) Group(8, &.{3}) else void = if (alpha) try Group(8, &.{3}).init(allocator, width) else {};
    defer if (alpha) opacity.deinit(allocator);
    var pixels = try RowPair.init(allocator, width);
    defer pixels.deinit(allocator);
    for (0..height) |y| {
        // The previous row is copied before requesting another batch. Thus the
        // upstream last-row lifetime guarantee is sufficient, including when
        // a producer recycles all older batches during more_lines.
        const row = try lines.next(width * components(kind));
        for (0..width) |x| {
            const pixel = pixels.current[x * 4 ..][0..4];
            if (gray) {
                pixel[0] = row[x];
            } else if (depth == 5) {
                const value = std.mem.readInt(u16, row[x * 2 ..][0..2], .little);
                pixel[0] = @intCast(value & 31);
                pixel[1] = @intCast((value >> 5) & 31);
                pixel[2] = @intCast((value >> 10) & 31);
            } else {
                @memcpy(pixel[0..components(kind)], row[x * components(kind) ..][0..components(kind)]);
            }
        }
        if (y == 0) {
            try color.encodeRow(true, width, writer, pixels);
            if (alpha) try opacity.encodeRow(true, width, writer, pixels);
        } else {
            try color.encodeRow(false, width, writer, pixels);
            if (alpha) try opacity.encodeRow(false, width, writer, pixels);
        }
        writer.rows += 1;
        pixels.advance();
    }
}

pub fn encode(allocator: Allocator, kind: c_int, width: c_int, height: c_int, lines: *Lines, writer: *Writer) DecodeError!c_int {
    if (kind < 1 or kind > 5) return error.UnsupportedType;
    if (width <= 0 or height <= 0) return error.InvalidHeader;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    if (@as(u64, w) * h > 512 * 1024 * 1024 - 1) return error.LimitExceeded;
    _ = try checkedLayout(w, h, kind, lines.stride, std.math.maxInt(usize));
    if (writer.output.len % 4 != 0) return error.OutputExhausted;
    try writer.header(0x4349_5551);
    try writer.header(0);
    try writer.header(@intCast(kind));
    try writer.header(@intCast(w));
    try writer.header(@intCast(h));
    switch (kind) {
        1 => try encodeImage(8, true, false, allocator, kind, w, h, lines, writer),
        2 => try encodeImage(5, false, false, allocator, kind, w, h, lines, writer),
        3, 4 => try encodeImage(8, false, false, allocator, kind, w, h, lines, writer),
        5 => try encodeImage(8, false, true, allocator, kind, w, h, lines, writer),
        else => unreachable,
    }
    try writer.flush();
    return @intCast(writer.count);
}

pub fn zig_quic_encode(kind: c_int, width: c_int, height: c_int, input: ?[*]const u8, num_lines: usize, stride: i64, output: [*]u8, size: usize, more_output: ?MoreOutput, more_lines: ?MoreLines, user: ?*anyopaque) callconv(.c) c_int {
    var lines: Lines = .{ .pointer = input, .count = num_lines, .stride = stride, .more = more_lines, .user = user };
    var writer: Writer = .{ .output = output[0..size], .more = more_output, .user = user };
    return encode(std.heap.page_allocator, kind, width, height, &lines, &writer) catch -1;
}

fn encoderAllocationTrial(allocator: Allocator, kind: c_int) !void {
    const input: [4]u8 = @splat(0);
    var output: [32]u8 = @splat(0xa5);
    var lines: Lines = .{ .pointer = &input, .count = 1, .stride = 4 };
    var writer: Writer = .{ .output = &output };
    const words = try encode(allocator, kind, 1, 1, &lines, &writer);
    try std.testing.expectEqual(@as(c_int, 7), words);
    const expected = testImage(@intCast(kind));
    // testImage deliberately fills unused residual bits; the encoder zeros them.
    try std.testing.expectEqualSlices(u8, expected[0..20], output[0..20]);
    var decoded: [4]u8 = undefined;
    try decode(allocator, output[0..28], 1, 1, &decoded);
    try std.testing.expectEqualSlices(u8, &input, &decoded);
    for (output[28..]) |v| try std.testing.expectEqual(@as(u8, 0xa5), v);
}

test "encoder allocation failures clean up and all formats round trip" {
    for (1..6) |kind| try std.testing.checkAllAllocationFailures(std.testing.allocator, encoderAllocationTrial, .{@as(c_int, @intCast(kind))});
}

test "output exhaustion and missing line callbacks free encoder storage" {
    const input: [8]u8 = @splat(0);
    var output: [64]u8 = undefined;
    for (0..7) |words| {
        var lines: Lines = .{ .pointer = &input, .count = 1, .stride = 4 };
        var writer: Writer = .{ .output = output[0 .. words * 4] };
        try std.testing.expectError(error.OutputExhausted, encode(std.testing.allocator, 5, 1, 1, &lines, &writer));
    }
    for (0..2) |count| {
        var lines: Lines = .{ .pointer = &input, .count = count, .stride = 4 };
        var writer: Writer = .{ .output = &output };
        try std.testing.expectError(error.LinesExhausted, encode(std.testing.allocator, 5, 1, 2, &lines, &writer));
    }
}
