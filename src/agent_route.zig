//! One ordered optional Agent consumer with bounded late-attachment replay.
const sync = @import("sync.zig");
pub fn Route(comptime Runtime: type, comptime Runner: type) type {
    return struct {
        const Self = @This();
        mutex: sync.Mutex = .{},
        runner: ?*Runner = null,
        pending: [64]Runtime.Event = undefined,
        head: usize = 0,
        count: usize = 0,
        bytes: usize = 0,
        lifecycle: u64 = 0,
        fn pop(self: *Self) void {
            const event = self.pending[self.head];
            self.bytes -= event.weight();
            // Only Agent-relevant owned variants are admitted below. Avoid
            // pulling unrelated display/native resource destruction into this
            // adapter or its independent consumer tests.
            switch (event.value) {
                .main => |value| if (value == .agent_message) {
                    value.agent_message.deinit();
                },
                .migration => |value| value.offer.release(),
                else => {},
            }
            self.head = (self.head + 1) % self.pending.len;
            self.count -= 1;
        }
        fn clear(self: *Self) void {
            while (self.count != 0) self.pop();
        }
        pub fn deinit(self: *Self) void {
            self.clear();
            self.mutex.deinit();
        }
        pub fn attach(self: *Self, runner: *Runner) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.runner != null) return error.AgentAlreadyAttached;
            for (0..self.count) |i| try runner.observe(self.pending[(self.head + i) % self.pending.len]);
            self.clear();
            self.runner = runner;
        }
        pub fn detach(self: *Self, runner: *Runner) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.runner == runner) self.runner = null;
        }
        pub fn observe(self: *Self, event: Runtime.Event) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.lifecycle != event.lifecycle) {
                self.clear();
                self.lifecycle = event.lifecycle;
            }
            switch (event.value) {
                .connected => {},
                .disconnected, .failed => {
                    self.clear();
                },
                .main => |value| switch (value) {
                    .agent_connected, .agent_disconnected, .agent_message => {},
                    else => return,
                },
                .migration => |value| {
                    if (value.kind != .completed or value.offer.mode != .switch_host) return;
                },
                else => return,
            }
            if (self.runner) |runner| return runner.observe(event);
            if (event.value == .disconnected or event.value == .failed) return;
            const weight = event.weight();
            const maximum = 32 * 1024 * 1024;
            if (weight > maximum) return;
            while (self.count == self.pending.len or weight > maximum - self.bytes) self.pop();
            var owned = event;
            switch (event.value) {
                .main => |v| if (v == .agent_message) {
                    owned.value.main.agent_message.data = v.agent_message.data.clone();
                },
                .migration => |v| {
                    owned.value.migration.offer = v.offer.retain();
                },
                else => {},
            }
            self.pending[(self.head + self.count) % self.pending.len] = owned;
            self.count += 1;
            self.bytes += weight;
        }
    };
}
