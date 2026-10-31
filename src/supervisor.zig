//! Native session supervision. Child is a Zig service bundle, not a transport
//! wrapper: World owns shared image/decoder resources; State owns each channel's
//! protocol/render state; step performs one handler and its physical completion.
//! Child.step returns .processed, .event, or .migration (owned optional bytes).
//! Async services additionally bind a generation-owned event sink and cancellation
//! token, then unbind/join all callbacks before the worker storage can be freed.
//! Child.World.create(allocator, clock)/destroy and State.create(allocator,world,
//! key)/destroy must be transactional. State.step(connection, cancellation) must
//! register cancellable resource waits. Event supplies deinit() and weight().
//!
//! One control thread owns migration decisions. Receivers and bounded connector
//! threads are always joined. All target allocation/thread creation precedes the
//! commit point; source services are retained across semi/seamless handoff.
const std = @import("std");
const sync = @import("sync.zig");
const cancellation = @import("cancel.zig");
const mailbox = @import("mailbox.zig");
const raw = @import("session.zig");
const endpoint = @import("endpoint.zig");
const child_connect = @import("child_connections.zig");
const main = @import("main_channel.zig");
const channel = @import("channel.zig");
const clock = @import("clock.zig");
const wire = @import("bytes.zig");
const barriers = @import("barrier.zig");
const migration = @import("migration.zig");
const handoff = @import("migration_coordinator.zig");
const agent = @import("agent.zig");
const link = @import("link.zig");
pub const Options = struct { maximum_channels: usize = 256, event_capacity: usize = 256, event_bytes: usize = 256 * 1024 * 1024, migration_bytes: usize = 256 * 1024 * 1024, video: child_connect.Video = .mjpeg };
// Session identity persists through migration and changes on switch-host.
pub const AgentEpoch = struct { session: u64, agent: u64 };
pub const Phase = enum { idle, connecting, ready, stopping, stopped };
pub fn Supervisor(comptime Child: type) type {
    return struct {
        const Self = @This();
        pub const Diagnostics = if (@hasDecl(Child, "Diagnostics")) Child.Diagnostics else struct {};
        pub const ChildConfiguration = if (@hasDecl(Child.World, "Configuration")) Child.World.Configuration else struct {
            pub fn retain(self: @This()) @This() {
                return self;
            }
            pub fn deinit(_: @This()) void {}
        };
        pub const Event = struct {
            mouse_mode: ?u32 = null,
            video_failure: ?@import("video_failure.zig").Failure = null,
            generation: u64,
            lifecycle: u64 = 0,
            key: barriers.Key = .{ .kind = 1, .id = 0 },
            value: union(enum) { connected, disconnected, failed: anyerror, main: main.Event, child: Child.Event, migration: struct { offer: *handoff.Offer, kind: handoff.EventKind, seamless: bool, failure: ?anyerror } },
            pub fn weight(self: Event) usize {
                return switch (self.value) {
                    .main => |event| switch (event) {
                        .agent_message => |m| m.data.bytes().len,
                        .migration => |m| m.storage.bytes().len,
                        else => 0,
                    },
                    .child => |event| event.weight(),
                    else => 0,
                };
            }
            pub fn deinit(self: Event) void {
                switch (self.value) {
                    .main => |event| event.deinit(),
                    .child => |event| event.deinit(),
                    .migration => |event| event.offer.release(),
                    else => {},
                }
            }
        };
        const Group = struct {
            next: ?*Group = null,
            network: *raw.Session,
            configuration: endpoint.Owned,
            media: ?*clock.Clock,
            main_connection: ?*raw.Connection = null,
            children: []*raw.Connection = &.{},
            bootstrap: ?main.Bootstrap = null,
            main_service: ?*main.Main = null,
            world: ?*Child.World = null,
            states: []*Child.State = &.{},
            workers: []Worker = &.{},
            armed: bool = false,
            adopted: bool = false,
            senders: usize = 0,
            child_senders: usize = 0,
            drain_thread: ?std.Thread = null,
            drain_failure: ?anyerror = null,
            drain_main: ?*main.Main = null,
            drain_armed: bool = false,
        };
        const Preparation = struct {
            next: ?*Preparation = null,
            owner: *Self,
            group: *Group,
            offer: *handoff.Offer,
            thread: ?std.Thread = null,
            failure: ?anyerror = null,
            accepted: bool = false,
            fn run(self: *Preparation) void {
                self.prepare() catch |err| {
                    self.failure = err;
                };
                self.owner.input.push(.{ .prepared = self }) catch {};
            }
            fn prepare(self: *Preparation) !void {
                const owner = self.owner;
                const group = self.group;
                const switching = self.offer.mode == .switch_host;
                const requests_seamless = self.offer.mode == .seamless;
                group.main_connection = try child_connect.connectOne(group.network, group.configuration.config, .{ .kind = 1, .id = 0 }, 0, owner.credentials.password(), owner.options.video, if (switching) null else requests_seamless);
                if (switching) {
                    try owner.createMain(group);
                    group.bootstrap = try group.main_service.?.bootstrap();
                } else if (requests_seamless and link.contains(group.main_connection.?.negotiated.?.channel(), 3)) {
                    self.accepted = try negotiate(&group.main_connection.?.channel, self.offer.mode.seamless);
                }
                group.children = try child_connect.connect(group.network, group.configuration.config, group.bootstrap.?.channels, group.bootstrap.?.session_id, owner.credentials.password(), owner.options.video);
                if (group.network.isCancelled()) return error.Cancelled;
            }
        };
        const Notice = union(enum) {
            event: Event,
            command: struct { worker: *Worker, generation: u64, event: main.Event },
            boundary: struct { worker: *Worker, generation: u64, data: ?wire.Slice },
            failed: struct { worker: *Worker, generation: u64, failure: anyerror, video_failure: ?@import("video_failure.zig").Failure = null },
            prepared: *Preparation,
            drained: *Group,
            pub fn weight(self: Notice) usize {
                return switch (self) {
                    .event => |event| event.weight(),
                    .command => |v| switch (v.event) {
                        .migration => |m| m.storage.bytes().len,
                        else => 0,
                    },
                    .boundary => |v| if (v.data) |data| data.bytes().len else 0,
                    else => 0,
                };
            }
            pub fn deinit(self: Notice) void {
                switch (self) {
                    .event => |event| event.deinit(),
                    .command => |v| v.event.deinit(),
                    .boundary => |v| {
                        if (v.data) |data| data.release();
                    },
                    else => {},
                }
            }
        };
        const Worker = struct {
            owner: *Self,
            group: *Group,
            connection: *raw.Connection,
            index: usize,
            generation: u64,
            lifecycle: u64,
            thread: ?std.Thread = null,
            token: cancellation.Token = .{},
            retiring: std.atomic.Value(bool) = .init(false),
            waiting: bool = false,
            paused: bool = false,
            boundary_seen: bool = false,
            // Main cancel and child boundary have no cross-socket ordering.
            // A cancelled prepared handoff permits one outstanding child boundary.
            cancelled_boundary: bool = false,
            payload: ?wire.Slice = null,
            fn run(self: *Worker) void {
                self.owner.mutex.lock();
                while (!self.group.armed and !self.owner.stopping and !self.retiring.load(.acquire)) self.owner.changed.wait(&self.owner.mutex);
                const run_now = !self.owner.stopping and !self.retiring.load(.acquire);
                self.owner.mutex.unlock();
                if (!run_now) return;
                self.loop() catch |err| {
                    if (!self.retiring.load(.acquire)) self.owner.input.pushCancellable(.{ .failed = .{ .worker = self, .generation = self.generation, .failure = err, .video_failure = self.videoFailure(err) } }, &self.token) catch {};
                };
            }
            fn park(self: *Worker, notice: Notice) !void {
                self.owner.mutex.lock();
                self.waiting = true;
                self.owner.mutex.unlock();
                self.owner.input.pushCancellable(notice, &self.token) catch |err| {
                    notice.deinit();
                    return err;
                };
                self.owner.mutex.lock();
                defer self.owner.mutex.unlock();
                while (self.waiting and !self.owner.stopping and !self.retiring.load(.acquire)) self.owner.changed.wait(&self.owner.mutex);
                if (self.owner.stopping or self.retiring.load(.acquire)) return error.Cancelled;
            }
            fn publish(self: *Worker, value: Event) !void {
                self.owner.input.pushCancellable(.{ .event = value }, &self.token) catch |err| {
                    value.deinit();
                    return err;
                };
            }
            fn asyncEvent(context: *anyopaque, event: Child.Event, token: *cancellation.Token) !void {
                const self: *Worker = @ptrCast(@alignCast(context));
                const value: Event = .{ .generation = self.generation, .lifecycle = self.lifecycle, .key = self.connection.key, .value = .{ .child = event } };
                self.owner.input.pushCancellable(.{ .event = value }, token) catch |err| {
                    value.deinit();
                    return err;
                };
            }
            fn videoFailure(self: *Worker, failure: anyerror) ?@import("video_failure.zig").Failure {
                if (comptime @hasDecl(Child.State, "videoFailure")) {
                    if (self.index != 0) return self.group.states[self.index - 1].videoFailure(failure);
                }
                return null;
            }
            fn asyncFailure(context: *anyopaque, failure: anyerror, token: *cancellation.Token) void {
                const self: *Worker = @ptrCast(@alignCast(context));
                self.owner.input.pushCancellable(.{ .failed = .{ .worker = self, .generation = self.generation, .failure = failure, .video_failure = self.videoFailure(failure) } }, token) catch return;
                self.connection.channel.cancel();
            }
            fn loop(self: *Worker) !void {
                const asynchronous = comptime @hasDecl(Child.State, "bind");
                if (asynchronous and self.index != 0) try self.group.states[self.index - 1].bind(.{ .context = self, .event = asyncEvent, .fail = asyncFailure }, &self.token);
                defer if (asynchronous and self.index != 0) self.group.states[self.index - 1].unbind();
                while (true) {
                    try self.token.check();
                    if (self.index == 0) {
                        const event = self.group.main_service.?.next() catch |err| {
                            if (err != error.MigrationRequested) return err;
                            const data = try self.group.main_service.?.takeMigration();
                            try self.park(.{ .boundary = .{ .worker = self, .generation = self.generation, .data = data } });
                            continue;
                        };
                        if (event) |value| {
                            if (value == .migration) try self.park(.{ .command = .{ .worker = self, .generation = self.generation, .event = value } }) else try self.publish(.{ .generation = self.generation, .lifecycle = self.lifecycle, .value = .{ .main = value } });
                        }
                    } else {
                        const step = try self.group.states[self.index - 1].step(&self.connection.channel, &self.token);
                        switch (step) {
                            .processed => {},
                            .event => |event| try self.publish(.{ .generation = self.generation, .lifecycle = self.lifecycle, .key = self.connection.key, .value = .{ .child = event } }),
                            .migration => |data| try self.park(.{ .boundary = .{ .worker = self, .generation = self.generation, .data = data } }),
                        }
                    }
                }
            }
        };
        child_configuration: ChildConfiguration = .{},
        retired_diagnostics: Diagnostics = .{},
        allocator: std.mem.Allocator,
        options: Options,
        mutex: sync.Mutex = .{},
        changed: sync.Condition = .{},
        phase: Phase = .idle,
        stopping: bool = false,
        generation: u64 = 1,
        lifecycle: u64 = 1,
        groups: ?*Group = null,
        active: ?*Group = null,
        preparations: ?*Preparation = null,
        prepared: ?*Preparation = null,
        retiring: ?*Group = null,
        controller: ?std.Thread = null,
        credentials: endpoint.Credentials = .{},
        coordinator: handoff.Coordinator,
        input: *mailbox.Mailbox(Notice),
        output: *mailbox.Mailbox(Event),
        failure: ?anyerror = null,
        failure_video: ?@import("video_failure.zig").Failure = null,
        failure_key: barriers.Key = .{ .kind = 1, .id = 0 },
        terminal_delivered: u2 = 0,
        sends_blocked: bool = false,
        migration_bytes: usize = 0,
        pub fn create(allocator: std.mem.Allocator, options: Options) !*Self {
            return createConfigured(allocator, options, .{});
        }
        /// Retains configuration independently of the caller and every group.
        pub fn createConfigured(allocator: std.mem.Allocator, options: Options, configuration: ChildConfiguration) !*Self {
            if (options.maximum_channels == 0 or options.maximum_channels > 65536 or options.event_capacity == 0) return error.InvalidConfiguration;
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const input = try mailbox.Mailbox(Notice).create(allocator, options.maximum_channels + 8, options.event_bytes);
            errdefer input.destroy();
            const output = try mailbox.Mailbox(Event).create(allocator, options.event_capacity, options.event_bytes);
            self.* = .{ .allocator = allocator, .options = options, .child_configuration = configuration.retain(), .coordinator = .{ .allocator = allocator }, .input = input, .output = output };
            return self;
        }
        fn newGroup(self: *Self, config: endpoint.Config) !*Group {
            const owned = try endpoint.Owned.init(self.allocator, config);
            errdefer owned.deinit();
            const network = try raw.Session.create(self.allocator, self.options.maximum_channels);
            errdefer network.destroy();
            const media = try self.allocator.create(clock.Clock);
            errdefer self.allocator.destroy(media);
            media.* = try clock.Clock.init();
            const group = try self.allocator.create(Group);
            group.* = .{ .network = network, .configuration = owned, .media = media };
            self.mutex.lock();
            if (self.stopping) {
                self.mutex.unlock();
                self.destroyGroup(group);
                return error.Cancelled;
            }
            group.next = self.groups;
            self.groups = group;
            self.mutex.unlock();
            return group;
        }
        fn createMain(self: *Self, group: *Group) !void {
            const service = try self.allocator.create(main.Main);
            service.* = main.Main.init(self.allocator, &group.main_connection.?.channel, .{ .context = group.media.?, .reset = clock.Clock.resetCallback });
            group.main_service = service;
        }
        fn createChildren(self: *Self, group: *Group) !void {
            group.world = if (comptime @hasDecl(Child.World, "Configuration")) try Child.World.createConfigured(self.allocator, group.media.?, self.child_configuration) else try Child.World.create(self.allocator, group.media.?);
            const states = try self.allocator.alloc(*Child.State, group.children.len);
            var created: usize = 0;
            errdefer {
                for (states[0..created]) |state| state.destroy();
                self.allocator.free(states);
            }
            for (group.children, states) |connection, *state| {
                state.* = try Child.State.create(self.allocator, group.world.?, connection.key);
                created += 1;
            }
            group.states = states;
        }
        /// The handle is available before connect so another caller can cancel a
        /// stalled bootstrap. Join the connect caller before destroy.
        pub fn connect(self: *Self, config: endpoint.Config, password: []const u8) !void {
            self.mutex.lock();
            if (self.phase != .idle or self.stopping) {
                self.mutex.unlock();
                return error.InvalidState;
            }
            self.phase = .connecting;
            self.mutex.unlock();
            self.establish(config, password) catch |err| {
                self.stopWith(err);
                self.cleanup();
                return err;
            };
        }
        fn establish(self: *Self, config: endpoint.Config, password: []const u8) !void {
            self.credentials = try endpoint.Credentials.init(password);
            const group = try self.newGroup(config);
            group.main_connection = try child_connect.connectOne(group.network, config, .{ .kind = 1, .id = 0 }, 0, self.credentials.password(), self.options.video, null);
            try self.createMain(group);
            group.bootstrap = try group.main_service.?.bootstrap();
            group.children = try child_connect.connect(group.network, config, group.bootstrap.?.channels, group.bootstrap.?.session_id, self.credentials.password(), self.options.video);
            try self.createChildren(group);
            try self.makeWorkers(group, self.generation, self.lifecycle);
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.stopping) return error.Cancelled;
            self.active = group;
            group.adopted = true;
            self.phase = .ready;
            self.controller = try std.Thread.spawn(.{}, control, .{self});
            group.armed = true;
            self.changed.broadcast();
        }
        fn makeWorkers(self: *Self, group: *Group, generation: u64, lifecycle: u64) !void {
            const workers = try self.allocator.alloc(Worker, group.children.len + 1);
            for (workers, 0..) |*worker, index| worker.* = .{ .owner = self, .group = group, .connection = if (index == 0) group.main_connection.? else group.children[index - 1], .index = index, .generation = generation, .lifecycle = lifecycle };
            self.mutex.lock();
            group.workers = workers;
            self.mutex.unlock();
            for (workers) |*worker| worker.thread = try std.Thread.spawn(.{}, Worker.run, .{worker});
        }
        fn isStopping(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.stopping;
        }
        /// The supervisor mutex pins adopted groups and their states. Component
        /// snapshots only acquire their own locks and never call back here.
        /// Preparing/failed targets are excluded. A semi/seamless transfer moves
        /// the states once; retiring empty source groups cannot double count.
        pub fn diagnosticsSnapshot(self: *Self) Diagnostics {
            self.mutex.lock();
            defer self.mutex.unlock();
            var value = self.retired_diagnostics;
            if (comptime @hasDecl(Child, "Diagnostics")) {
                var current = self.groups;
                while (current) |group| : (current = group.next) {
                    if (group.adopted) for (group.states) |state| value.accumulate(state.diagnosticsSnapshot());
                }
                if (self.active) |group| if (group.world) |world| {
                    const memory = world.memorySnapshot();
                    value.surface_bytes = memory.used;
                    value.maximum_surface_bytes = memory.maximum;
                };
            }
            return value;
        }
        pub fn cancel(self: *Self) void {
            self.stopWith(null);
        }
        fn stopWith(self: *Self, failure: ?anyerror) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.stopping) return;
            self.stopping = true;
            self.phase = .stopping;
            self.failure = failure;
            self.input.close();
            self.output.close();
            var current = self.groups;
            while (current) |group| : (current = group.next) {
                group.network.cancel();
                for (group.workers) |*worker| {
                    worker.retiring.store(true, .release);
                    worker.token.cancel();
                }
            }
            self.changed.broadcast();
        }
        pub fn join(self: *Self) void {
            if (self.controller) |thread| {
                thread.join();
                self.controller = null;
            }
        }
        /// Reuse this stable Runtime after cancellation. The API owner must
        /// serialize reset/connect/destroy and join external next/send/connect
        /// callers first. Concurrent Source hooks remain safe: they see a closed
        /// epoch until reset commits, and stale ACKs carry the old lifecycle.
        pub fn reset(self: *Self, video: child_connect.Video) !void {
            self.mutex.lock();
            if (self.phase == .idle and !self.stopping) {
                self.options.video = video;
                self.mutex.unlock();
                return;
            }
            if (!self.stopping or self.phase == .connecting) {
                self.mutex.unlock();
                return error.InvalidState;
            }
            self.mutex.unlock();
            self.join();
            self.cleanup();
            self.mutex.lock();
            defer self.mutex.unlock();
            std.debug.assert(self.phase == .stopped and self.groups == null);
            const next_generation = try std.math.add(u64, self.generation, 1);
            const next_lifecycle = try std.math.add(u64, self.lifecycle, 1);
            // Cleanup joined workers; queued notices own only their payloads,
            // never the now-retired Worker/Group pointers carried as metadata.
            while (self.input.next()) |notice| notice.deinit();
            while (self.output.next()) |event| event.deinit();
            self.input.reopen() catch unreachable;
            self.output.reopen() catch unreachable;
            self.coordinator.deinit();
            self.coordinator = .{ .allocator = self.allocator };
            self.credentials.deinit();
            self.retired_diagnostics = .{};
            self.failure = null;
            self.failure_video = null;
            self.failure_key = .{ .kind = 1, .id = 0 };
            self.terminal_delivered = 0;
            self.sends_blocked = false;
            self.migration_bytes = 0;
            self.generation = next_generation;
            self.lifecycle = next_lifecycle;
            self.options.video = video;
            self.stopping = false;
            self.phase = .idle;
            self.changed.broadcast();
        }
        pub fn destroy(self: *Self) void {
            self.cancel();
            self.join();
            self.cleanup();
            self.coordinator.deinit();
            self.credentials.deinit();
            self.input.destroy();
            self.output.destroy();
            self.changed.deinit();
            self.mutex.deinit();
            self.child_configuration.deinit();
            self.allocator.destroy(self);
        }
        pub fn next(self: *Self) ?Event {
            while (self.output.next()) |event| {
                self.mutex.lock();
                const generation = self.generation;
                const stopping = self.stopping;
                self.mutex.unlock();
                if (event.value == .main or event.value == .child) {
                    if (stopping or event.generation != generation) {
                        event.deinit();
                        continue;
                    }
                }
                return event;
            }
            self.mutex.lock();
            defer self.mutex.unlock();
            if (!self.stopping) return null;
            if (self.terminal_delivered == 0) {
                self.terminal_delivered = 1;
                if (self.failure) |failure| return .{ .generation = self.generation, .lifecycle = self.lifecycle, .key = self.failure_key, .video_failure = self.failure_video, .value = .{ .failed = failure } };
            }
            if (self.terminal_delivered == 1) {
                self.terminal_delivered = 2;
                return .{ .generation = self.generation, .lifecycle = self.lifecycle, .value = .disconnected };
            }
            return null;
        }
        fn lease(self: *Self, key: barriers.Key) !struct { generation: u64, lifecycle: u64, group: *Group, connection: *raw.Connection, main_service: *main.Main, child_state: ?*Child.State } {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.stopping or self.phase != .ready) return error.ConnectionClosed;
            if (self.sends_blocked) return error.InvalidState;
            const group = self.active.?;
            var connection: ?*raw.Connection = null;
            var child_state: ?*Child.State = null;
            if (key.index() == group.main_connection.?.key.index()) {
                connection = group.main_connection;
            } else {
                for (group.children, group.states) |child, state| {
                    if (child.key.index() == key.index()) {
                        connection = child;
                        child_state = state;
                        break;
                    }
                }
            }
            const found = connection orelse return error.UnknownChannel;
            group.senders += 1;
            if (child_state != null) group.child_senders += 1;
            return .{ .generation = self.generation, .lifecycle = self.lifecycle, .group = group, .connection = found, .main_service = group.main_service.?, .child_state = child_state };
        }
        fn releaseLease(self: *Self, group: *Group, child: bool) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            std.debug.assert(group.senders > 0);
            group.senders -= 1;
            if (child) group.child_senders -= 1;
            self.changed.broadcast();
        }
        pub fn send(self: *Self, key: barriers.Key, kind: u16, bytes: []const u8) !void {
            const captured = try self.lease(key);
            defer self.releaseLease(captured.group, captured.child_state != null);
            try captured.connection.channel.send(kind, bytes);
        }
        pub fn sendInput(self: *Self, id: u8, input: @import("inputs.zig").Input) !void {
            const captured = try self.lease(.{ .kind = 3, .id = id });
            defer self.releaseLease(captured.group, true);
            try captured.child_state.?.sendInput(&captured.connection.channel, input);
        }
        pub fn sendRecord(self: *Self, id: u8, input: @import("audio.zig").RecordInput) !void {
            const captured = try self.lease(.{ .kind = 6, .id = id });
            defer self.releaseLease(captured.group, true);
            try captured.child_state.?.sendRecord(&captured.connection.channel, input);
        }
        /// A capture worker is bound to the logical guest and record START.
        /// Cancellation during an uncertain write closes that exact channel;
        /// this is required to avoid reusing a possibly partial wire frame.
        pub fn sendRecordAt(self: *Self, id: u8, lifecycle: u64, epoch: u64, input: @import("audio.zig").RecordInput, token: *cancellation.Token) !void {
            try token.check();
            const captured = try self.lease(.{ .kind = 6, .id = id });
            defer self.releaseLease(captured.group, true);
            if (captured.lifecycle != lifecycle) return error.AudioStreamChanged;
            var connection: @import("audio_send.zig").Cancellable(channel.Channel) = .{ .connection = &captured.connection.channel, .token = token };
            try captured.child_state.?.sendRecordAt(&connection, input, epoch);
        }
        pub fn reportPlaybackDelay(self: *Self, id: u8, delay: u32) !void {
            const captured = try self.lease(.{ .kind = 5, .id = id });
            defer self.releaseLease(captured.group, true);
            try captured.child_state.?.reportPlaybackDelay(delay);
        }
        pub fn sendSmartcard(self: *Self, id: u8, message: @import("smartcard_wire.zig").Message) !void {
            const captured = try self.lease(.{ .kind = 8, .id = id });
            defer self.releaseLease(captured.group, true);
            try captured.child_state.?.sendSmartcard(&captured.connection.channel, message);
        }
        pub fn sendUSB(self: *Self, id: u8, bytes: []const u8) !void {
            const captured = try self.lease(.{ .kind = 9, .id = id });
            defer self.releaseLease(captured.group, true);
            try captured.child_state.?.sendUSB(&captured.connection.channel, bytes);
        }
        /// USB may continue across same-guest handoff. Only a lease rejected
        /// BEFORE entering the wire can be deferred; an uncertain write fails
        /// the backend instead of replaying an external device operation.
        pub fn sendUSBAt(self: *Self, id: u8, lifecycle: u64, bytes: []const u8, token: *cancellation.Token) !void {
            try token.check();
            const captured = self.lease(.{ .kind = 9, .id = id }) catch |err| {
                if (err == error.InvalidState) return error.USBHandoffPending;
                return err;
            };
            defer self.releaseLease(captured.group, true);
            if (captured.lifecycle != lifecycle) return error.USBGuestChanged;
            var connection: @import("audio_send.zig").Cancellable(channel.Channel) = .{ .connection = &captured.connection.channel, .token = token };
            try captured.child_state.?.sendUSB(&connection, bytes);
        }
        pub fn sendWebDAV(self: *Self, id: u8, client: i64, bytes: []const u8) !void {
            const captured = try self.lease(.{ .kind = 11, .id = id });
            defer self.releaseLease(captured.group, true);
            try captured.child_state.?.sendWebDAV(&captured.connection.channel, client, bytes);
        }
        /// Responses belong to the exact supervision generation, as in the
        /// Swift backend. A pinned send never moves to a replacement transport.
        pub fn sendWebDAVAt(self: *Self, id: u8, generation: u64, client: i64, bytes: []const u8, token: *cancellation.Token) !void {
            try token.check();
            const captured = self.lease(.{ .kind = 11, .id = id }) catch |err| return self.webdavSendFailure(generation, err);
            defer self.releaseLease(captured.group, true);
            if (captured.generation != generation) return error.StaleWebDAVGeneration;
            var connection: @import("audio_send.zig").Cancellable(channel.Channel) = .{ .connection = &captured.connection.channel, .token = token };
            captured.child_state.?.sendWebDAV(&connection, client, bytes) catch |err| return self.webdavSendFailure(generation, err);
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.generation != generation) return error.StaleWebDAVGeneration;
        }
        fn webdavSendFailure(self: *Self, generation: u64, err: anyerror) anyerror {
            self.mutex.lock();
            defer self.mutex.unlock();
            // Migration cancels old child sockets before transferring state.
            // That cancellation must retire the old response without killing
            // the reusable host backend serving the new transport.
            return if (self.generation != generation) error.StaleWebDAVGeneration else err;
        }
        pub fn setFrameDemand(self: *Self, channel_id: u8, surface_id: u32, demanded: bool) !void {
            const captured = try self.lease(.{ .kind = 2, .id = channel_id });
            defer self.releaseLease(captured.group, true);
            try captured.child_state.?.setFrameDemand(surface_id, demanded);
        }
        pub fn acknowledgeFrame(self: *Self, channel_id: u8, revision: @import("surface.zig").Revision) !void {
            const captured = try self.lease(.{ .kind = 2, .id = channel_id });
            defer self.releaseLease(captured.group, true);
            try captured.child_state.?.acknowledgeFrame(revision);
        }
        /// Source demand/ACK captured before a guest switch must not affect the
        /// new Store even if its local Surface lifecycle/revision numbers repeat.
        pub fn setFrameDemandAt(self: *Self, lifecycle: u64, channel_id: u8, surface_id: u32, demanded: bool) !void {
            const captured = try self.lease(.{ .kind = 2, .id = channel_id });
            defer self.releaseLease(captured.group, true);
            if (captured.lifecycle != lifecycle) return error.StaleDesktopEpoch;
            try captured.child_state.?.setFrameDemand(surface_id, demanded);
        }
        pub fn acknowledgeFrameAt(self: *Self, lifecycle: u64, channel_id: u8, revision: @import("surface.zig").Revision) !void {
            const captured = try self.lease(.{ .kind = 2, .id = channel_id });
            defer self.releaseLease(captured.group, true);
            if (captured.lifecycle != lifecycle) return error.StaleDesktopEpoch;
            try captured.child_state.?.acknowledgeFrame(revision);
        }
        pub fn flushFrames(self: *Self, channel_id: u8) !void {
            const captured = try self.lease(.{ .kind = 2, .id = channel_id });
            defer self.releaseLease(captured.group, true);
            try captured.child_state.?.flushFrames();
        }
        pub fn frameMetrics(self: *Self, channel_id: u8) !@import("frame_publisher.zig").Metrics {
            const captured = try self.lease(.{ .kind = 2, .id = channel_id });
            defer self.releaseLease(captured.group, true);
            return captured.child_state.?.frameMetrics();
        }
        pub fn sendAgent(self: *Self, protocol: u32, kind: u32, opaque_id: u64, data: []const u8, token: *agent.SendToken) !bool {
            const captured = try self.lease(.{ .kind = 1, .id = 0 });
            defer self.releaseLease(captured.group, captured.child_state != null);
            return captured.main_service.sender.send(protocol, kind, opaque_id, data, token);
        }
        /// Pins the exact sender across handoff. A per-call cancellation token
        /// wakes that sender even after it has moved to a retired group.
        pub fn sendAgentCancellable(self: *Self, protocol: u32, kind: u32, opaque_id: u64, data: []const u8, token: *cancellation.Token) !bool {
            return self.sendAgentAt(null, protocol, kind, opaque_id, data, token);
        }
        pub fn sendAgentAt(self: *Self, expected: ?AgentEpoch, protocol: u32, kind: u32, opaque_id: u64, data: []const u8, token: *cancellation.Token) !bool {
            const captured = try self.lease(.{ .kind = 1, .id = 0 });
            defer self.releaseLease(captured.group, false);
            if (expected) |epoch_value| {
                if (epoch_value.session != captured.lifecycle) return error.StaleAgentGeneration;
            }
            const Linked = struct {
                sender: *agent.Sender,
                send: agent.SendToken = .{},
                fn wake(p: *anyopaque) void {
                    const linked: *@This() = @ptrCast(@alignCast(p));
                    linked.sender.cancelSend(&linked.send);
                }
            };
            var linked: Linked = .{ .sender = &captured.main_service.sender };
            var registration: cancellation.Registration = .{ .context = &linked, .wake = Linked.wake };
            token.register(&registration);
            defer token.unregister(&registration);
            return linked.sender.sendAt(if (expected) |e| e.agent else null, protocol, kind, opaque_id, data, &linked.send);
        }
        fn emit(self: *Self, event: Event) !void {
            self.output.push(event) catch |err| {
                event.deinit();
                return err;
            };
        }
        fn control(self: *Self) void {
            self.emit(.{ .mouse_mode = self.active.?.bootstrap.?.mouse.current, .generation = self.generation, .lifecycle = self.lifecycle, .value = .connected }) catch {};
            while (self.input.next()) |notice| {
                self.mutex.lock();
                const stopping = self.stopping;
                self.mutex.unlock();
                if (stopping) {
                    notice.deinit();
                    break;
                }
                self.handle(notice) catch |err| {
                    self.stopWith(err);
                    break;
                };
            }
            self.cleanup();
        }
        fn handle(self: *Self, notice: Notice) !void {
            switch (notice) {
                .event => |event| {
                    if (event.generation != self.generation) {
                        event.deinit();
                        return;
                    }
                    try self.emit(event);
                },
                .failed => |value| {
                    if (value.generation == self.generation) {
                        self.mutex.lock();
                        self.failure_video = value.video_failure;
                        self.failure_key = value.worker.connection.key;
                        self.mutex.unlock();
                        return value.failure;
                    }
                },
                .command => |value| {
                    defer value.event.deinit();
                    if (value.generation != self.generation) return;
                    const transitions = try self.coordinator.receive(value.event.migration.command);
                    defer transitions.deinit();
                    try self.actions(&transitions);
                    self.releaseWorker(value.worker);
                },
                .boundary => |value| {
                    if (value.generation != self.generation) {
                        if (value.data) |data| data.release();
                        return;
                    }
                    try self.boundary(value.worker, value.data);
                },
                .prepared => |preparation| try self.preparationReady(preparation),
                .drained => |group| {
                    if (group.drain_thread) |thread| {
                        thread.join();
                        group.drain_thread = null;
                    }
                    const failure = group.drain_failure;
                    self.retiring = null;
                    self.removeGroup(group);
                    if (failure) |err| return err;
                },
            }
        }
        fn releaseWorker(self: *Self, worker: *Worker) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (!worker.paused) worker.waiting = false;
            self.changed.broadcast();
        }
        fn actions(self: *Self, list: *const handoff.Actions) anyerror!void {
            for (list.items()) |action| switch (action) {
                .event => |event| try self.emit(.{ .mouse_mode = if (event.kind == .completed and event.offer.mode == .switch_host) self.active.?.bootstrap.?.mouse.current else null, .generation = self.generation, .lifecycle = self.lifecycle, .value = .{ .migration = .{ .offer = event.offer.retain(), .kind = event.kind, .seamless = event.seamless, .failure = event.failure } } }),
                .send => |reply| try self.active.?.main_service.?.sendMigration(reply),
                .violation => |failure| return failure,
                .cancel => |offer| self.cancelPreparation(offer.id, true),
                .prepare, .switch_host => |offer| self.launch(offer) catch |err| {
                    const failed = if (offer.mode == .switch_host) self.coordinator.finished(offer.id, err) else self.coordinator.preparationFailed(offer.id, err);
                    defer failed.deinit();
                    try self.actions(&failed);
                },
                .commit => |offer| {
                    const preparation = self.prepared orelse return error.MissingMigrationTarget;
                    if (preparation.offer.id != offer.id) return error.StaleMigration;
                    self.commit(preparation, false) catch |err| {
                        if (self.isStopping()) return err;
                        const failed = self.coordinator.finished(offer.id, err);
                        defer failed.deinit();
                        try self.actions(&failed);
                        self.cancelPreparation(offer.id, true);
                    };
                },
            };
        }
        fn cloneBootstrap(self: *Self, source: main.Bootstrap) !main.Bootstrap {
            var result = source;
            result.allocator = self.allocator;
            result.channels = try self.allocator.dupe(barriers.Key, source.channels);
            return result;
        }
        fn launch(self: *Self, offer: *handoff.Offer) !void {
            const active = self.active orelse return error.ConnectionClosed;
            const config = try endpoint.destination(active.configuration.config, offer.destination);
            const group = try self.newGroup(config);
            errdefer self.removeGroup(group);
            if (offer.mode != .switch_host) group.bootstrap = try self.cloneBootstrap(active.bootstrap.?);
            const preparation = try self.allocator.create(Preparation);
            errdefer self.allocator.destroy(preparation);
            preparation.* = .{ .owner = self, .group = group, .offer = offer.retain() };
            errdefer preparation.offer.release();
            // The control thread alone edits this list; cancel only walks groups.
            preparation.thread = try std.Thread.spawn(.{}, Preparation.run, .{preparation});
            preparation.next = self.preparations;
            self.preparations = preparation;
        }
        fn removePreparation(self: *Self, preparation: *Preparation, keep_group: bool) void {
            if (preparation.thread) |thread| {
                thread.join();
                preparation.thread = null;
            }
            var slot = &self.preparations;
            while (slot.*) |current| {
                if (current == preparation) {
                    slot.* = current.next;
                    break;
                }
                slot = &current.next;
            }
            if (self.prepared == preparation) self.prepared = null;
            if (!keep_group) self.removeGroup(preparation.group);
            preparation.offer.release();
            self.allocator.destroy(preparation);
        }
        fn preparationReady(self: *Self, preparation: *Preparation) !void {
            if (preparation.thread) |thread| {
                thread.join();
                preparation.thread = null;
            }
            const current = self.coordinator.offer;
            if (current == null or current.?.id != preparation.offer.id or (self.coordinator.phase != .preparing and self.coordinator.phase != .switching)) {
                self.removePreparation(preparation, false);
                return;
            }
            if (preparation.failure) |failure| {
                const failed = if (self.coordinator.phase == .switching) self.coordinator.finished(preparation.offer.id, failure) else self.coordinator.preparationFailed(preparation.offer.id, failure);
                defer failed.deinit();
                self.removePreparation(preparation, false);
                try self.actions(&failed);
                return;
            }
            self.prepared = preparation;
            if (preparation.offer.mode == .switch_host) {
                self.commit(preparation, true) catch |err| {
                    if (self.isStopping()) return err;
                    const failed = self.coordinator.finished(preparation.offer.id, err);
                    defer failed.deinit();
                    self.removePreparation(preparation, false);
                    try self.actions(&failed);
                };
            } else {
                const ready = self.coordinator.prepared(preparation.offer.id, preparation.accepted);
                defer ready.deinit();
                try self.actions(&ready);
            }
        }
        fn resumeSource(self: *Self, cancelled_seamless: bool) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.sends_blocked = false;
            self.migration_bytes = 0;
            if (self.active) |group| {
                for (group.workers) |*worker| {
                    if (worker.payload) |payload| payload.release();
                    worker.payload = null;
                    if (cancelled_seamless and worker.index != 0 and !worker.boundary_seen) worker.cancelled_boundary = true;
                    worker.boundary_seen = false;
                    if (worker.paused) {
                        worker.connection.channel.resumeMigration();
                        worker.paused = false;
                        worker.waiting = false;
                    }
                }
            }
            self.changed.broadcast();
        }
        fn cancelPreparation(self: *Self, id: u64, resume_source: bool) void {
            const cancelled_seamless = if (self.prepared) |p| p.offer.id == id and p.accepted else false;
            var current = self.preparations;
            while (current) |preparation| {
                const following = preparation.next;
                if (preparation.offer.id == id) {
                    preparation.group.network.cancel();
                    if (preparation.thread == null) self.removePreparation(preparation, false);
                }
                current = following;
            }
            if (resume_source) self.resumeSource(cancelled_seamless);
        }
        fn boundary(self: *Self, worker: *Worker, data: ?wire.Slice) !void {
            var adopted = false;
            defer if (!adopted) {
                if (data) |value| value.release();
            };
            if (self.coordinator.phase != .ready or !self.coordinator.seamless or self.prepared == null) {
                if (!worker.cancelled_boundary) return error.UnexpectedMigrationBoundary;
                worker.cancelled_boundary = false;
                worker.connection.channel.resumeMigration();
                self.releaseWorker(worker);
                return;
            }
            worker.cancelled_boundary = false;
            if (worker.group != self.active.? or worker.boundary_seen) return error.DuplicateMigrationBoundary;
            const size = if (data) |value| value.bytes().len else 0;
            if (size > self.options.migration_bytes - self.migration_bytes) return error.MessageTooLarge;
            self.mutex.lock();
            worker.payload = data;
            worker.boundary_seen = true;
            worker.paused = true;
            self.sends_blocked = true;
            self.migration_bytes += size;
            self.mutex.unlock();
            adopted = true;
            for (self.active.?.workers) |other| if (!other.boundary_seen) return;
            const preparation = self.prepared.?;
            const actions_list = self.coordinator.seamlessCommit(preparation.offer.id);
            defer actions_list.deinit();
            try self.actions(&actions_list);
            try self.validateInventory(self.active.?, preparation.group);
            // Migration-data effects are never retried; failure here terminates the
            // session because the source has already committed its wire boundaries.
            for (self.active.?.workers) |source| if (source.payload) |payload| {
                const destination_connection = findConnection(preparation.group, source.connection.key) orelse return error.MissingMigrationChannel;
                try destination_connection.channel.send(5, payload.bytes());
            };
            try self.commit(preparation, false);
        }
        fn findConnection(group: *Group, key: barriers.Key) ?*raw.Connection {
            if (group.main_connection.?.key.index() == key.index()) return group.main_connection;
            for (group.children) |connection| if (connection.key.index() == key.index()) return connection;
            return null;
        }
        fn validateInventory(_: *Self, source: *Group, target: *Group) !void {
            if (source.children.len != target.children.len or target.main_connection.?.key.index() != source.main_connection.?.key.index()) return error.MigrationInventoryMismatch;
            for (source.children) |connection| if (findConnection(target, connection.key) == null) return error.MigrationInventoryMismatch;
        }
        fn joinWorkers(group: *Group) void {
            for (group.workers) |*worker| if (worker.thread) |thread| {
                thread.join();
                worker.thread = null;
            };
        }
        fn retireWorkers(self: *Self, group: *Group, preserve_main: bool) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (group.workers) |*worker| {
                worker.retiring.store(true, .release);
                worker.token.cancel();
                if (worker.index != 0 or !preserve_main) worker.connection.channel.cancel();
            }
            self.changed.broadcast();
        }
        fn commit(self: *Self, preparation: *Preparation, switching: bool) !void {
            const source = self.active orelse return error.ConnectionClosed;
            const target = preparation.group;
            if (self.retiring != null) return error.RetiringMainStillActive;
            if (!switching) {
                try self.validateInventory(source, target);
                if (!source.workers[0].waiting) return error.MainNotAtMigrationBoundary;
            }
            const next_generation = try std.math.add(u64, self.generation, 1);
            const next_lifecycle = if (switching) try std.math.add(u64, self.lifecycle, 1) else self.lifecycle;
            if (switching) try self.createChildren(target);
            try self.makeWorkers(target, next_generation, next_lifecycle);
            // Last fallible native checks precede the source retirement point.
            for (target.workers) |worker| try worker.connection.transport.connect();
            self.mutex.lock();
            if (self.stopping) {
                self.mutex.unlock();
                return error.Cancelled;
            }
            if (!switching) {
                source.drain_main = source.main_service;
                source.drain_thread = std.Thread.spawn(.{}, drain, .{ self, source }) catch |err| {
                    self.mutex.unlock();
                    return err;
                };
            }
            self.sends_blocked = true;
            self.generation = next_generation;
            self.lifecycle = next_lifecycle;
            self.mutex.unlock();
            self.retireWorkers(source, !switching);
            joinWorkers(source);
            self.mutex.lock();
            // Child sends have been cancelled at the old sockets. Drain their
            // state leases before transferring state to the new group's owner.
            // Main Agent sends retain their independent retired-connection drain.
            while (source.child_senders != 0) self.changed.wait(&self.mutex);
            if (self.stopping) {
                self.mutex.unlock();
                return error.Cancelled;
            }
            if (!switching) {
                // Receiver workers are joined. Main's Sender alone may still own an
                // old connection; its captured message is drained independently.
                _ = source.main_service.?.replace(&target.main_connection.?.channel) catch |err| {
                    self.mutex.unlock();
                    self.stopWith(err);
                    return err;
                };
                target.main_service = source.main_service;
                source.main_service = null;
                target.world = source.world;
                source.world = null;
                // Descriptor order may differ at the destination. Reorder the
                // retained state pointers to the destination connection inventory.
                for (target.children, 0..) |connection, index| {
                    var match = index;
                    while (match < source.children.len and source.children[match].key.index() != connection.key.index()) match += 1;
                    std.debug.assert(match < source.children.len);
                    std.mem.swap(*Child.State, &source.states[index], &source.states[match]);
                    std.mem.swap(*raw.Connection, &source.children[index], &source.children[match]);
                }
                target.states = source.states;
                source.states = &.{};
                target.media.?.deinit();
                self.allocator.destroy(target.media.?);
                target.media = source.media;
                source.media = null;
            }
            self.active = target;
            target.adopted = true;
            target.armed = true;
            self.sends_blocked = false;
            self.migration_bytes = 0;
            if (!switching) {
                self.retiring = source;
                source.drain_armed = true;
            }
            self.changed.broadcast();
            self.mutex.unlock();
            const id = preparation.offer.id;
            self.removePreparation(preparation, true);
            if (switching) self.removeGroup(source);
            const finished = self.coordinator.finished(id, null);
            defer finished.deinit();
            try self.actions(&finished);
        }
        fn drain(self: *Self, group: *Group) void {
            self.mutex.lock();
            while (!group.drain_armed and !self.stopping) self.changed.wait(&self.mutex);
            const stopping = self.stopping;
            self.mutex.unlock();
            if (!stopping) group.drain_main.?.sender.waitRetired(&group.main_connection.?.channel) catch |err| {
                group.drain_failure = err;
            };
            group.main_connection.?.channel.cancel();
            self.input.push(.{ .drained = group }) catch {};
        }
        fn removeGroup(self: *Self, group: *Group) void {
            group.network.cancel();
            self.retireWorkers(group, false);
            joinWorkers(group);
            if (group.drain_thread) |thread| {
                thread.join();
                group.drain_thread = null;
            }
            self.mutex.lock();
            while (group.senders != 0) self.changed.wait(&self.mutex);
            var slot = &self.groups;
            while (slot.*) |current| {
                if (current == group) {
                    if (comptime @hasDecl(Child, "Diagnostics")) {
                        if (group.adopted) for (group.states) |state| self.retired_diagnostics.accumulate(state.diagnosticsSnapshot());
                    }
                    if (self.active == group) self.active = null;
                    slot.* = current.next;
                    break;
                }
                slot = &current.next;
            }
            self.mutex.unlock();
            self.destroyGroup(group);
        }
        fn destroyGroup(self: *Self, group: *Group) void {
            for (group.workers) |*worker| {
                if (worker.payload) |payload| payload.release();
                worker.token.deinit();
            }
            self.allocator.free(group.workers);
            if (group.main_service) |service| {
                service.deinit();
                self.allocator.destroy(service);
            }
            for (group.states) |state| state.destroy();
            self.allocator.free(group.states);
            if (group.world) |world| world.destroy();
            if (group.bootstrap) |bootstrap| bootstrap.deinit();
            self.allocator.free(group.children);
            if (group.media) |media| {
                media.deinit();
                self.allocator.destroy(media);
            }
            group.network.destroy();
            group.configuration.deinit();
            self.allocator.destroy(group);
        }
        fn cleanup(self: *Self) void {
            self.input.close();
            self.output.close();
            var preparation = self.preparations;
            while (preparation) |p| {
                p.group.network.cancel();
                if (p.thread) |thread| {
                    thread.join();
                    p.thread = null;
                }
                preparation = p.next;
            }
            while (self.preparations) |p| {
                self.preparations = p.next;
                p.offer.release();
                self.allocator.destroy(p);
            }
            self.prepared = null;
            // A retired Main drain borrows the Main service now owned by the
            // active target. Join every drain before destroying either group.
            var joining = self.groups;
            while (joining) |group| : (joining = group.next) {
                self.retireWorkers(group, false);
                joinWorkers(group);
                if (group.drain_thread) |thread| {
                    thread.join();
                    group.drain_thread = null;
                }
            }
            // A semi/seamless handoff moves Main into the target, while a
            // previously admitted send still leases the source group. A drain
            // may exit early during cancellation, and completing its wire write
            // does not join that caller's token-unregistration/return path.
            // Wake all senders, then join ALL group leases before destroying any
            // transferred service. Waiting only on each group's own senders can
            // otherwise destroy target Main underneath a source-owned caller.
            var cancelling = self.groups;
            while (cancelling) |group| : (cancelling = group.next) {
                if (group.main_service) |service| service.cancel();
            }
            self.mutex.lock();
            var leasing = self.groups;
            while (leasing) |group| : (leasing = group.next) {
                while (group.senders != 0) self.changed.wait(&self.mutex);
            }
            self.mutex.unlock();
            while (self.groups) |group| self.removeGroup(group);
            self.mutex.lock();
            self.active = null;
            self.retiring = null;
            self.phase = .stopped;
            self.changed.broadcast();
            self.mutex.unlock();
            self.credentials.deinit();
        }
        fn negotiate(connection: *channel.Channel, version: u32) !bool {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, version, .little);
            try connection.send(110, &bytes);
            const event = try connection.receive();
            defer event.deinit();
            if (event != .message) return error.UnexpectedMigration;
            const command = (try migration.decode(event.message.kind, event.message.body.bytes())) orelse return error.UnexpectedMigration;
            const accepted = switch (command) {
                .accepted => true,
                .rejected => false,
                else => return error.UnexpectedMigration,
            };
            try connection.complete();
            return accepted;
        }
    };
}
