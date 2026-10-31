//! Ordered late attachment of the two optional audio consumers. All event
//! retention and replay live here, outside the Swift compatibility layer.
const sync = @import("sync.zig");
pub fn Route(comptime Runtime: type, comptime Runner: type) type {
    return struct {
        const Self = @This();
        const Slot = struct {
            runner: ?*Runner = null,
            pending: [32]Runtime.Event = undefined,
            head: usize = 0,
            count: usize = 0,
            bytes: usize = 0,
            fn pop(self: *Slot) void {
                const event = self.pending[self.head];
                self.bytes -= event.weight();
                event.deinit();
                self.head = (self.head + 1) % self.pending.len;
                self.count -= 1;
            }
            fn clear(self: *Slot) void {
                while (self.count != 0) self.pop();
            }
        };
        mutex: sync.Mutex = .{},
        slots: [2]Slot = .{ .{}, .{} },
        lifecycle: u64 = 0,
        pub fn deinit(self: *Self) void {
            for (&self.slots) |*slot| slot.clear();
            self.mutex.deinit();
        }
        // The caller owns runner, and must detach before destroying it. No
        // user callbacks run under this mutex; observe only enqueues native work.
        pub fn attach(self: *Self, recording: bool, runner: *Runner) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            const slot = &self.slots[@intFromBool(recording)];
            if (slot.runner != null) return error.AudioAlreadyAttached;
            for (0..slot.count) |i| try runner.observe(slot.pending[(slot.head + i) % slot.pending.len]);
            slot.clear();
            slot.runner = runner;
        }
        pub fn detach(self: *Self, recording: bool, runner: *Runner) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            const slot = &self.slots[@intFromBool(recording)];
            if (slot.runner == runner) slot.runner = null;
        }
        pub fn observe(self: *Self, event: Runtime.Event) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.lifecycle != event.lifecycle) {
                for (&self.slots) |*slot| slot.clear();
                self.lifecycle = event.lifecycle;
            }
            const recording: bool = switch (event.value) {
                .child => |child| switch (child) {
                    .playback => false,
                    .record => true,
                    else => return,
                },
                .connected, .migration, .disconnected, .failed => {
                    // No owned migration/control payload needs to be buffered:
                    // each child event carries its own logical guest lifecycle.
                    if (event.value == .disconnected or event.value == .failed)
                        for (&self.slots) |*slot| {
                            slot.clear();
                        };
                    for (&self.slots) |*slot| if (slot.runner) |runner| try runner.observe(event);
                    return;
                },
                else => return,
            };
            if (event.key.id != 0) return;
            const slot = &self.slots[@intFromBool(recording)];
            if (slot.runner) |runner| return runner.observe(event);
            const maximum = 32 * 1024 * 1024;
            const weight = event.weight();
            // This is a late-attachment replay cache, not a second mandatory
            // consumer. The public stream enforces Record overflow while it is
            // unconsumed; direct public consumers may drain it indefinitely.
            if (weight > maximum) return;
            while (slot.count == slot.pending.len or weight > maximum - slot.bytes) slot.pop();
            var owned = event;
            const audio = if (recording) &owned.value.child.record else &owned.value.child.playback;
            if (audio.* == .packet) audio.packet.data = audio.packet.data.clone();
            slot.pending[(slot.head + slot.count) % slot.pending.len] = owned;
            slot.count += 1;
            slot.bytes += weight;
        }
    };
}
