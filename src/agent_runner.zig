//! Optional joined Agent executor. Callers feed ordered Desktop observations;
//! clipboard polling and token-backpressure retries run here, not in Swift.
//! Runtime is borrowed until destroy. Board is retained. All public methods are
//! thread-safe except destroy, which follows joined callers. No callback enters
//! user code: owned output events are drained with next().
const std = @import("std");
const core = @import("agent_manager.zig");
const binding = @import("agent_session.zig");
const sync = @import("sync.zig");
const cancel = @import("cancel.zig");
const clock = @import("clock.zig");
const bytes = @import("bytes.zig");
const monitors = @import("monitor_config.zig");
const files = @import("file_transfer.zig");
const source = @import("file_source.zig");
extern "c" fn pthread_cond_timedwait_relative_np(*std.c.pthread_cond_t, *std.c.pthread_mutex_t, *const std.c.timespec) std.c.E;
pub const Options = struct { first_file_id: u32 = 1, automatic_poll: bool = true, manager: core.Options = .{ .clipboard_enabled = false }, poll_ms: u32 = 250, maximum_queued_bytes: usize = 32 * 1024 * 1024 };
pub const Output = union(enum) {
    agent: core.Event,
    failed: struct { request: u64, reason: anyerror, actual: u64 = 0, maximum: u64 = 0 },
    completed: u64,
    file_accepted: struct { request: u64, key: files.Key },
    pub fn deinit(self: Output) void {
        switch (self) {
            .agent => |v| v.deinit(),
            else => {},
        }
    }
    fn weight(self: Output) usize {
        return switch (self) {
            .agent => |v| switch (v) {
                .clipboard => |clip| switch (clip) {
                    .guest_text => |text| text.bytes().len,
                    else => 0,
                },
                .file => |file| switch (file) {
                    .queued => |q| q.name.bytes().len,
                    else => 0,
                },
                else => 0,
            },
            else => 0,
        };
    }
};
pub fn Runner(comptime Runtime: type, comptime Board: type) type {
    return struct {
        const Self = @This();
        const Bound = binding.Binding(Runtime);
        // Borrowed local publication keeps caller storage alive until the worker
        // consumes it. It never copies oversized text into the bounded wire queue.
        const Publication = struct {
            text: []const u8,
            revision: u64,
            mutex: sync.Mutex = .{},
            changed: sync.Condition = .{},
            done: bool = false,
            failure: ?anyerror = error.Cancelled,
            fn finish(self: *Publication) void {
                self.mutex.lock();
                self.done = true;
                self.changed.broadcast();
                self.mutex.unlock();
            }
        };
        const Command = union(enum) {
            observe: Runtime.Event,
            publish_borrowed: *Publication,
            policy: struct { revision: u64, enabled: bool },
            layout: struct { request: u64, configuration: monitors.Configuration },
            file: struct { request: u64, file: *source.Source, name: bytes.Slice },
            cancel_file: struct { request: u64, key: files.Key },
            synchronize: u64,
            barrier: u64,
            publish: struct { request: u64, revision: u64, text: bytes.Slice },
            fn deinit(self: Command) void {
                switch (self) {
                    .observe => |v| releaseObservation(v),
                    .publish_borrowed => |v| v.finish(),
                    .publish => |v| v.text.release(),
                    .file => |v| {
                        v.file.release();
                        v.name.release();
                    },
                    else => {},
                }
            }
            fn weight(self: Command) usize {
                return switch (self) {
                    .observe => |v| v.weight(),
                    .file => |v| v.name.bytes().len,
                    .publish => |v| v.text.bytes().len,
                    else => 0,
                };
            }
            fn request(self: Command) u64 {
                return switch (self) {
                    .observe, .policy, .publish_borrowed => 0,
                    .layout => |v| v.request,
                    .file => |v| v.request,
                    .cancel_file => |v| v.request,
                    .publish => |v| v.request,
                    .synchronize, .barrier => |v| v,
                };
            }
        };
        allocator: std.mem.Allocator,
        board: Board,
        bound: *Bound = undefined,
        options: Options,
        timebase: std.c.mach_timebase_info_data,
        mutex: sync.Mutex = .{},
        changed: sync.Condition = .{},
        thread: ?std.Thread = null,
        stopping: bool = false,
        finished: bool = false,
        failure: ?anyerror = null,
        token: cancel.Token = .{},
        access: cancel.Token = .{},
        desired_enabled: bool,
        policy: u64 = 1,
        applied_policy: u64 = 1,
        commands: [64]Command = undefined,
        head: usize = 0,
        count: usize = 0,
        queued_bytes: usize = 0,
        outputs: [64]Output = undefined,
        out_head: usize = 0,
        out_count: usize = 0,
        out_bytes: usize = 0,
        metrics: @import("agent_metrics.zig").Metrics = .{},
        next_file_id: u32 = 1,
        pub fn create(a: std.mem.Allocator, runtime: *Runtime, board: Board, options: Options) !*Self {
            if (options.first_file_id == 0) return error.InvalidLimits;
            if (options.poll_ms < 10 or options.maximum_queued_bytes > 64 * 1024 * 1024) return error.InvalidLimits;
            var timebase: std.c.mach_timebase_info_data = undefined;
            if (std.c.mach_timebase_info(&timebase) != 0 or timebase.denom == 0) return error.ClockUnavailable;
            const self = try a.create(Self);
            self.* = .{ .allocator = a, .board = board.retain(), .options = options, .timebase = timebase, .desired_enabled = options.manager.clipboard_enabled };
            errdefer {
                self.clear();
                self.board.deinit();
                self.access.deinit();
                self.token.deinit();
                self.changed.deinit();
                self.mutex.deinit();
                a.destroy(self);
            }
            self.bound = try Bound.create(a, runtime, .{ .context = self, .check = check, .write_text = writeText, .emit = emit }, options.manager);
            errdefer self.bound.destroy();
            self.bound.manager.transfers.next_id = options.first_file_id;
            self.next_file_id = options.first_file_id;
            self.thread = try std.Thread.spawn(.{}, run, .{self});
            return self;
        }
        fn clear(self: *Self) void {
            for (0..self.count) |i| self.commands[(self.head + i) % self.commands.len].deinit();
            self.count = 0;
            for (0..self.out_count) |i| self.outputs[(self.out_head + i) % self.outputs.len].deinit();
            self.out_count = 0;
        }
        /// Can run on main while a queued AppKit operation is pending. Queued work
        /// cancels without requiring main to drain; an already-running effect joins.
        pub fn stop(self: *Self) void {
            self.mutex.lock();
            self.stopping = true;
            self.access.cancel();
            self.changed.broadcast();
            self.mutex.unlock();
            self.token.cancel();
        }
        pub fn join(self: *Self) void {
            self.stop();
            if (self.thread) |thread| thread.join();
            self.thread = null;
        }
        pub fn destroy(self: *Self) void {
            self.join();
            self.bound.destroy();
            self.clear();
            self.board.deinit();
            self.access.deinit();
            self.token.deinit();
            self.changed.deinit();
            self.mutex.deinit();
            self.allocator.destroy(self);
        }
        pub fn diagnostics(self: *Self) @import("agent_metrics.zig").Metrics {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.metrics;
        }
        pub fn nextFileID(self: *Self) u32 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.next_file_id;
        }
        fn snapshotMetrics(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.metrics = self.bound.manager.metrics;
            self.next_file_id = self.bound.manager.transfers.next_id;
        }
        pub fn status(self: *Self) struct { finished: bool, failure: ?anyerror } {
            self.mutex.lock();
            defer self.mutex.unlock();
            return .{ .finished = self.finished, .failure = self.failure };
        }
        pub fn next(self: *Self) ?Output {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.out_count == 0) return null;
            const value = self.outputs[self.out_head];
            self.out_head = (self.out_head + 1) % self.outputs.len;
            self.out_count -= 1;
            self.out_bytes -= value.weight();
            return value;
        }
        fn output(self: *Self, value: Output) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            const size = value.weight();
            if (self.out_count == self.outputs.len or size > self.options.maximum_queued_bytes - self.out_bytes) {
                value.deinit();
                self.failure = error.AgentEventQueueFull;
                self.stopping = true;
                self.changed.broadcast();
                return;
            }
            self.outputs[(self.out_head + self.out_count) % self.outputs.len] = value;
            self.out_count += 1;
            self.out_bytes += size;
        }
        fn emit(p: *anyopaque, event: core.Event) void {
            const self: *Self = @ptrCast(@alignCast(p));
            self.output(.{ .agent = event });
        }
        fn check(p: *anyopaque) !void {
            const self: *Self = @ptrCast(@alignCast(p));
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.failure) |err| return err;
            if (self.stopping) return error.Cancelled;
        }
        fn writeText(p: *anyopaque, text: []const u8, _: *cancel.Token) !i64 {
            const self: *Self = @ptrCast(@alignCast(p));
            self.mutex.lock();
            const enabled = !self.stopping and self.desired_enabled and self.applied_policy == self.policy;
            self.mutex.unlock();
            if (!enabled) return error.PasteboardRevoked;
            const result = try self.board.write(text, self.bound.manager.state.maximum_text, &self.access);
            defer result.deinit();
            return result.change_count;
        }
        /// Immediate revocation cancels a queued host read/write. The worker clears
        /// previously queued guest writes before applying even a rapid disable/enable.
        pub fn setClipboardEnabled(self: *Self, enabled: bool) !void {
            self.mutex.lock();
            var locked = true;
            defer if (locked) self.mutex.unlock();
            if (self.stopping) return error.Cancelled;
            if (self.desired_enabled == enabled) return;
            if (self.count == self.commands.len) {
                // Revocation cannot silently fail because the command queue is full.
                self.desired_enabled = false;
                self.access.cancel();
                self.failure = error.AgentWorkQueueFull;
                self.stopping = true;
                self.changed.broadcast();
                self.mutex.unlock();
                locked = false;
                self.token.cancel();
                return error.AgentWorkQueueFull;
            }
            self.policy = try std.math.add(u64, self.policy, 1);
            self.commands[(self.head + self.count) % self.commands.len] = .{ .policy = .{ .revision = self.policy, .enabled = enabled } };
            self.count += 1;
            self.desired_enabled = enabled;
            self.access.cancel();
            self.changed.broadcast();
        }
        fn enqueue(self: *Self, command: Command) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.stopping) return error.Cancelled;
            const size = command.weight();
            if (self.count == self.commands.len or size > self.options.maximum_queued_bytes - self.queued_bytes) return error.AgentWorkQueueFull;
            self.commands[(self.head + self.count) % self.commands.len] = command;
            self.count += 1;
            self.queued_bytes += size;
            self.changed.broadcast();
        }
        /// Borrows input; copies only Agent-relevant observations. Display/audio
        /// payloads are never retained by this executor. Queue overflow is explicit.
        fn releaseObservation(event: Runtime.Event) void {
            switch (event.value) {
                .main => |v| switch (v) {
                    .agent_message => |m| m.deinit(),
                    else => {},
                },
                .migration => |v| v.offer.release(),
                else => {},
            }
        }
        pub fn observe(self: *Self, event: Runtime.Event) !void {
            var copy = event;
            switch (event.value) {
                .connected, .disconnected, .failed => {},
                .main => |v| switch (v) {
                    .agent_connected, .agent_disconnected => {},
                    .agent_message => |message| {
                        copy.value.main.agent_message.data = message.data.clone();
                    },
                    else => return,
                },
                .migration => |v| {
                    if (v.kind != .completed or v.offer.mode != .switch_host) return;
                    copy.value.migration.offer = v.offer.retain();
                },
                else => return,
            }
            errdefer releaseObservation(copy);
            try self.enqueue(.{ .observe = copy });
        }
        pub fn synchronize(self: *Self, request: u64) !void {
            try self.enqueue(.{ .synchronize = request });
        }
        pub fn barrier(self: *Self, request: u64) !void {
            try self.enqueue(.{ .barrier = request });
        }
        pub fn publish(self: *Self, request: u64, text: []const u8) !void {
            if (text.len > 16 * 1024 * 1024 or !std.unicode.utf8ValidateSlice(text)) return error.InvalidUTF8;
            self.mutex.lock();
            const revision = self.policy;
            self.mutex.unlock();
            const owned = try bytes.Slice.copy(self.allocator, text);
            errdefer owned.release();
            try self.enqueue(.{ .publish = .{ .request = request, .revision = revision, .text = owned } });
        }
        /// Blocking, off-main-thread only for an AppKit Board. Caller storage is
        /// borrowed through return, including cancellation/stop. No owned queue
        /// byte limit is raised; the fixed command count also bounds these borrows.
        pub fn publishBorrowed(self: *Self, text: []const u8) !void {
            if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUTF8;
            self.mutex.lock();
            const revision = self.policy;
            self.mutex.unlock();
            var publication: Publication = .{ .text = text, .revision = revision };
            defer publication.changed.deinit();
            defer publication.mutex.deinit();
            try self.enqueue(.{ .publish_borrowed = &publication });
            publication.mutex.lock();
            defer publication.mutex.unlock();
            while (!publication.done) publication.changed.wait(&publication.mutex);
            if (publication.failure) |err| return err;
        }
        fn publishText(self: *Self, revision: u64, text: []const u8) !void {
            self.mutex.lock();
            const enabled = self.desired_enabled and !self.stopping and self.applied_policy == revision and self.policy == revision;
            self.mutex.unlock();
            if (!enabled) return;
            const snapshot = try self.board.write(text, self.bound.manager.state.maximum_text, &self.access);
            defer snapshot.deinit();
            // Observe what was actually written, just as the original Swift
            // publish path does. Oversized snapshots carry metadata, never bytes.
            if (snapshot.oversized) try self.bound.manager.localOversized(snapshot.change_count, snapshot.size) else try self.bound.manager.localChanged(snapshot.change_count, try snapshot.bytes());
        }
        pub fn requestDisplay(self: *Self, request: u64, configuration: monitors.Configuration) !void {
            try self.enqueue(.{ .layout = .{ .request = request, .configuration = configuration } });
        }
        /// The pinned file remains alive through admission; request correlates the
        /// asynchronous key/failure response. No host path is opened on the worker.
        pub fn queueFile(self: *Self, request: u64, file: *source.Source, name: []const u8) !void {
            if (name.len > 4096) return error.InvalidFileName;
            const owned = try bytes.Slice.copy(self.allocator, name);
            errdefer owned.release();
            const retained = file.retain();
            errdefer retained.release();
            try self.enqueue(.{ .file = .{ .request = request, .file = retained, .name = owned } });
        }
        pub fn cancelFile(self: *Self, request: u64, key: files.Key) !void {
            try self.enqueue(.{ .cancel_file = .{ .request = request, .key = key } });
        }
        fn applyPolicy(self: *Self, revision: u64, enabled: bool) !void {
            // Commands preserve policy ordering relative to incoming messages.
            try self.bound.manager.setClipboardEnabled(enabled);
            self.mutex.lock();
            defer self.mutex.unlock();
            self.applied_policy = revision;
            if (revision == self.policy and !self.stopping) {
                self.access.deinit();
                self.access = .{};
            }
        }
        fn poll(self: *Self) !void {
            self.mutex.lock();
            const revision = self.policy;
            const enabled = self.desired_enabled and self.applied_policy == revision and !self.stopping;
            self.mutex.unlock();
            if (!enabled or !self.bound.manager.state.agent_connected) return;
            const snapshot = try self.board.snapshot(self.bound.manager.state.maximum_text, &self.access);
            defer snapshot.deinit();
            self.mutex.lock();
            const current = self.policy == revision and !self.stopping;
            self.mutex.unlock();
            if (!current) return;
            if (snapshot.oversized) try self.bound.manager.localOversized(snapshot.change_count, snapshot.size) else try self.bound.manager.localChanged(snapshot.change_count, try snapshot.bytes());
        }
        fn execute(self: *Self, command: Command) !void {
            switch (command) {
                .observe => |event| try self.bound.observe(event),
                .barrier => {},
                .synchronize => try self.poll(),
                .publish => |v| try self.publishText(v.revision, v.text.bytes()),
                .publish_borrowed => |v| {
                    self.publishText(v.revision, v.text) catch |err| {
                        v.failure = err;
                        return err;
                    };
                    v.failure = null;
                },
                .policy => |v| try self.applyPolicy(v.revision, v.enabled),
                .layout => |v| try self.bound.manager.requestDisplay(v.configuration),
                .cancel_file => |v| try self.bound.manager.cancelFile(v.key),
                .file => |v| {
                    const key = try self.bound.manager.queueFile(v.file, v.name.bytes());
                    self.output(.{ .file_accepted = .{ .request = v.request, .key = key } });
                },
            }
        }
        fn report(self: *Self, request: u64, err: anyerror) void {
            if (err == error.Cancelled or err == error.PasteboardRevoked or err == error.PasteboardBusy) return;
            self.output(.{ .failed = .{ .request = request, .reason = err } });
        }
        fn run(self: *Self) void {
            defer {
                self.bound.manager.disconnect();
                self.snapshotMetrics();
                self.mutex.lock();
                // Wake queued borrowed publishers even when failure/stop exits
                // before their command. No caller waits for eventual destruction.
                for (0..self.count) |i| self.commands[(self.head + i) % self.commands.len].deinit();
                self.count = 0;
                self.queued_bytes = 0;
                self.finished = true;
                self.changed.broadcast();
                self.mutex.unlock();
            }
            const interval = @as(u64, self.options.poll_ms) * std.time.ns_per_ms;
            var deadline = clock.nanoseconds(self.timebase) + interval;
            var more = false;
            while (true) {
                self.mutex.lock();
                if (self.stopping) {
                    self.mutex.unlock();
                    return;
                }
                var command: ?Command = null;
                if (self.count != 0) {
                    command = self.commands[self.head];
                    self.head = (self.head + 1) % self.commands.len;
                    self.count -= 1;
                    self.queued_bytes -= command.?.weight();
                }
                self.mutex.unlock();
                var completion: u64 = 0;
                if (command) |value| {
                    defer value.deinit();
                    completion = switch (value) {
                        .barrier, .synchronize => |v| v,
                        .publish => |v| v.request,
                        .layout => |v| v.request,
                        .cancel_file => |v| v.request,
                        else => 0,
                    };
                    self.execute(value) catch |err| {
                        completion = 0;
                        if (value.request() != 0) {
                            self.output(.{ .failed = .{ .request = value.request(), .reason = err, .actual = if (value == .file) value.file.file.size else 0, .maximum = if (value == .file) self.options.manager.file_limits.maximum_bytes else 0 } });
                        } else if (value != .publish_borrowed) self.report(0, err);
                        if (value == .policy) {
                            self.mutex.lock();
                            self.failure = err;
                            self.stopping = true;
                            self.mutex.unlock();
                            return;
                        }
                    };
                }
                self.mutex.lock();
                const stop_now = self.stopping;
                self.mutex.unlock();
                if (stop_now) return;
                var now = clock.nanoseconds(self.timebase);
                if (now >= deadline) {
                    if (self.options.automatic_poll) self.poll() catch |err| self.report(0, err);
                    deadline = now + interval;
                }
                more = if (self.bound.manager.pump(&self.token, 32)) |state| state == .more else |err| blk: {
                    self.report(0, err);
                    break :blk false;
                };
                self.snapshotMetrics();
                if (completion != 0) self.output(.{ .completed = completion });
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.stopping) return;
                if (self.count != 0 or self.policy != self.applied_policy or more) continue;
                now = clock.nanoseconds(self.timebase);
                if (now < deadline) {
                    const wait = deadline - now;
                    const timeout: std.c.timespec = .{ .sec = @intCast(wait / std.time.ns_per_s), .nsec = @intCast(wait % std.time.ns_per_s) };
                    _ = pthread_cond_timedwait_relative_np(&self.changed.value, &self.mutex.value, &timeout);
                }
            }
        }
    };
}
