const std = @import("std");
const s = @import("spice");
const a = std.heap.c_allocator;
const Histograms = struct { values: [3]s.timing.Histogram = @splat(.{}) };
export fn histogram_create() ?*Histograms {
    const h = a.create(Histograms) catch return null;
    h.* = .{};
    return h;
}
export fn histogram_destroy(h: *Histograms) void {
    a.destroy(h);
}
export fn histogram_step(h: *Histograms, op: u32, slot: u32, other: u32, seconds: i64, attoseconds: i64, output: [*]f64) void {
    if (slot >= 3 or other >= 3) return;
    switch (op) {
        0 => h.values[slot].duration(seconds, attoseconds),
        1 => h.values[slot].accumulate(h.values[other]),
        2 => h.values[slot] = .{},
        else => return,
    }
    const result = h.values[slot].summary();
    output[0] = @floatFromInt(result.sample_count);
    output[1] = result.p95_ms orelse -1;
    output[2] = result.maximum_ms orelse -1;
}
export fn record_fixture(bytes: [*]const u8, length: usize, mode: u32, output: [*]u8, capacity: usize) isize {
    const parsed = if (mode == 1) s.interaction_record.decode(a, bytes[0..length]) catch return -1 else std.json.parseFromSlice(s.interaction_record.Record, a, bytes[0..length], .{}) catch return -1;
    defer parsed.deinit();
    const encoded = parsed.value.encode(a) catch return -1;
    defer a.free(encoded);
    if (encoded.len > capacity) return -1;
    @memcpy(output[0..encoded.len], encoded);
    return @intCast(encoded.len);
}
export fn marker_fixture(bytes: [*]const u8, length: usize, width: usize, height: usize, stride: usize, token: [*]const u8, token_len: usize, checksum: u32, output: [*]u64) void {
    @memset(output[0..4], 0);
    switch (s.interaction_marker.detect(bytes[0..length], width, height, stride, token[0..token_len], checksum)) {
        .none => {},
        .ambiguous => |count| {
            output[0] = 2;
            output[1] = count;
        },
        .exact => |p| {
            output[0] = 1;
            output[1] = p.token;
            output[2] = p.revision;
            output[3] = p.checksum;
        },
    }
}

fn identity(n: u64) s.interaction_trace.Identity {
    return .{ .desktop_generation = n / 100 + 1, .channel = @intCast(n % 2), .surface = @intCast(n % 3), .surface_generation = n / 10 + 1, .revision = n, .sequence = n + 1 };
}
export fn trace_create() ?*s.interaction_trace.Assembler {
    return s.interaction_trace.Assembler.create(a, .{ .pair_id = "pair", .version = "zig", .run_id = "run", .order = 1, .action = .click, .token = "0123456789abcdef", .checksum = 0xaabbccdd }) catch null;
}
export fn trace_destroy(value: *s.interaction_trace.Assembler) void {
    value.destroy();
}
fn optional(value: u64) ?u64 {
    return if (value == std.math.maxInt(u64)) null else value;
}
export fn trace_step(value: *s.interaction_trace.Assembler, op: u32, n: u64, x: u64, y: u64, z: u64, w: u64) c_int {
    const id = identity(n);
    switch (op) {
        0 => value.hostInput(x, y, z),
        1 => value.sendCompleted(x, optional(y)),
        2 => value.motionAcknowledged(x),
        3 => value.guestEvidence(x, y, z),
        4 => value.observe(id, optional(z), optional(w), switch (x) {
            0 => .none,
            1 => .{ .exact = .{ .token = 0x0123456789abcdef, .revision = y, .checksum = 0xaabbccdd } },
            else => .{ .ambiguous = 2 },
        }),
        5 => value.select(id, x, y),
        6 => value.commit(id, x),
        7 => {
            _ = value.presented(id, x);
        },
        8 => value.drop(id),
        9 => value.retireSurface(.{ .channel = id.channel, .surface = id.surface }, x) catch return -1,
        10 => value.retireDesktop(x),
        else => return -1,
    }
    return 0;
}
export fn trace_finish(value: *s.interaction_trace.Assembler, output: [*]u8, capacity: usize) isize {
    const bytes = value.finishEncoded(a, null) catch return -1;
    defer a.free(bytes);
    if (bytes.len > capacity) return -1;
    @memcpy(output[0..bytes.len], bytes);
    return @intCast(bytes.len);
}
