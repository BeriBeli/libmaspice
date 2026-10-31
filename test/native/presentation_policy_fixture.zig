const std = @import("std");
const s = @import("spice");
const a = std.heap.c_allocator;
const State = struct {
    pacing: s.presentation_policy.Pacing = .{},
    metal: s.presentation_policy.MetalRecovery = .{ .allocator = a, .maximum_attempts = 8192 },
    drop: s.presentation_policy.DropRecovery = .{},
    attempts: std.ArrayList(s.presentation_policy.MetalRecovery.Attempt) = .empty,
};
fn revision(value: u64) s.desktop_snapshot.Revision {
    return .{ .channel = @intCast(value % 3), .surface = .{ .id = @intCast(value % 5), .lifecycle = value / 10, .value = value } };
}
export fn policy_create() ?*State {
    const self = a.create(State) catch return null;
    self.* = .{};
    return self;
}
export fn policy_destroy(self: *State) void {
    self.metal.deinit();
    self.attempts.deinit(a);
    a.destroy(self);
}
export fn policy_step(self: *State, op: u32, x: i64, y: i64, z: i64) i64 {
    switch (op) {
        0 => return switch (self.pacing.ready()) {
            .select_immediately => 1,
            .wait_display_link => 2,
            else => -99,
        },
        1 => return switch (self.pacing.tick(x != 0)) {
            .select_on_display_link => 3,
            .pause_display_link => 4,
            else => -99,
        },
        2 => self.pacing.reset(),
        10 => {
            const attempt = self.metal.begin(revision(@intCast(x))) catch return -99;
            self.attempts.append(a, attempt) catch return -99;
            return @intCast(self.attempts.items.len - 1);
        },
        11 => return @backingInt(self.metal.complete(self.attempts.items[@intCast(x)], z != 0, if (y < 0) null else revision(@intCast(y)))),
        12 => self.metal.cancel(self.attempts.items[@intCast(x)]),
        13 => self.metal.reset(),
        20 => self.drop.selected(revision(@intCast(x))),
        21 => return @intFromBool(self.drop.dropped(revision(@intCast(x)), if (y < 0) null else revision(@intCast(y)), z != 0)),
        22 => self.drop.succeeded(revision(@intCast(x))),
        23 => self.drop.reset(),
        else => return -99,
    }
    return 0;
}
