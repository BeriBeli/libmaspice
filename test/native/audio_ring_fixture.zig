const std = @import("std");
const s = @import("spice");
const a = std.heap.c_allocator;
const Ring = s.audio_ring.Ring;
export fn audio_ring_create(bytes: usize, slots: usize, staged: bool) ?*Ring {
    const value = a.create(Ring) catch return null;
    value.* = Ring.init(a, .{ .bytes = bytes, .slots = slots }, staged) catch {
        a.destroy(value);
        return null;
    };
    return value;
}
export fn audio_ring_destroy(value: *Ring) void {
    value.deinit();
    a.destroy(value);
}
fn publish(_: void, commit: *Ring.Commit) s.audio_ring.Result {
    return commit.publish();
}
// All output memory is caller-owned, including dequeue materialization copies.
export fn audio_ring_step(value: *Ring, op: u32, timestamp: u32, input: [*]const u8, size: usize, output: [*]u8, meta: *[33]u64) c_int {
    meta.* = @splat(0);
    switch (op) {
        0, 5 => {
            const result = if (op == 0) value.enqueue(timestamp, input[0..size]) else value.enqueueStaged(timestamp, input[0..size], null, {}, publish);
            switch (result) {
                .enqueued => |v| {
                    meta[1] = v.dropped_packets;
                    meta[2] = v.dropped_bytes;
                },
                .oversized => |n| {
                    meta[0] = 1;
                    meta[1] = n;
                },
                .lease_conflict => |n| {
                    meta[0] = 2;
                    meta[1] = n;
                },
                .closed => |n| {
                    meta[0] = 3;
                    meta[1] = n;
                },
            }
        },
        1 => {
            meta[0] = 4;
            meta[1] = value.read(output[0..size]);
            meta[4] = size;
        },
        2 => {
            meta[0] = 5;
            if (value.dequeue(a) catch return -1) |packet| {
                defer packet.deinit();
                meta[0] = 6;
                meta[3] = packet.timestamp;
                meta[4] = packet.bytes.len;
                @memcpy(output[0..packet.bytes.len], packet.bytes);
            }
        },
        3 => value.reset(),
        4 => value.close(),
        else => return -2,
    }
    const d = value.diagnostics();
    meta.*[5..].* = .{ d.queued_bytes, d.queued_slots, d.enqueued_packets, d.enqueued_bytes, d.dequeued_packets, d.dequeued_bytes, d.read_calls, d.wraparound_copies, d.underflows, d.overruns, d.dropped_packets, d.dropped_bytes, d.reset_count, d.close_count, d.lease_starts, d.lease_finishes, d.materializations, d.materialized_bytes, d.lease_conflict_drops, d.blocked_reads, d.blocked_dequeues, d.deferred_resets, d.deferred_closes, @intFromBool(d.active_lease), @intFromBool(d.closed), d.preallocated_bytes, d.staging_bytes, d.capacity.slots };
    return 0;
}
