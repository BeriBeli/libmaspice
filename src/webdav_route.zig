//! Optional channel consumers. WebDAV packets received before attachment remain
//! solely on the public stream, matching the original session contract.
const sync = @import("sync.zig");
pub fn Route(comptime Runtime: type, comptime Runner: type) type {
    return struct {
        const Self = @This();
        mutex: sync.Mutex = .{},
        slots: [256]?*Runner = @splat(null),
        pub fn deinit(self: *Self) void {
            self.mutex.deinit();
        }
        /// Borrow until detach. attach and observe share ordering. No blocking
        /// device calls, network sends or foreign callbacks run under this lock.
        pub fn attach(self: *Self, runtime: *Runtime, runner: *Runner) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            const slot = &self.slots[runner.options.channel_id];
            if (slot.* != null) return error.WebDAVAlreadyAttached;
            runtime.mutex.lock();
            const ready = runtime.phase == .ready and !runtime.stopping;
            var found = false;
            if (ready) if (runtime.active) |group| {
                for (group.children) |child| {
                    if (child.key.kind == 11 and child.key.id == runner.options.channel_id) {
                        found = true;
                        break;
                    }
                }
            };
            const generation = runtime.generation;
            const lifecycle = runtime.lifecycle;
            runtime.mutex.unlock();
            if (!found) return error.WebDAVNotReady;
            try runner.observe(.{ .generation = generation, .lifecycle = lifecycle, .value = .connected });
            slot.* = runner;
        }
        pub fn detach(self: *Self, runner: *Runner) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            const slot = &self.slots[runner.options.channel_id];
            if (slot.* == runner) slot.* = null;
        }
        /// True means the packet went to its attached backend; do not duplicate
        /// it into an unused mandatory public queue.
        pub fn observe(self: *Self, event: Runtime.Event) !bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            switch (event.value) {
                .child => |child| switch (child) {
                    .webdav => {
                        const slot = &self.slots[event.key.id];
                        if (slot.*) |runner| {
                            runner.observe(event) catch |err| {
                                if (err == error.Closed) {
                                    slot.* = null;
                                    return false;
                                }
                                return err;
                            };
                            return true;
                        }
                    },
                    else => {},
                },
                .connected, .disconnected, .failed, .migration => {
                    for (&self.slots) |*slot| if (slot.*) |runner| {
                        runner.observe(event) catch |err| {
                            if (err != error.Closed) return err;
                            slot.* = null;
                        };
                    };
                },
                else => {},
            }
            return false;
        }
    };
}
