//! Serialized desktop Agent manager. The owner drives events and bounded pump
//! turns on its executor. Host callbacks cannot reenter the manager; cancellation
//! is a separate thread-safe Token. No host clipboard read is implicit: pass a
//! snapshot only when the user's synchronization policy permits it.
const std = @import("std");
const clipboard = @import("clipboard.zig");
const protocol = @import("agent_services_wire.zig");
const wire = @import("bytes.zig");
const agent = @import("agent.zig");
const monitors = @import("monitor_config.zig");
const files = @import("file_transfer.zig");
const source = @import("file_source.zig");
const cancel = @import("cancel.zig");
pub const DisplayEvent = union(enum) { queued: monitors.Request, sent: monitors.Request, acknowledged: monitors.Request, rejected: monitors.Request, unsupported: monitors.Request, failed: struct { request: ?monitors.Request, reason: anyerror } };
pub const Event = union(enum) {
    clipboard: clipboard.Event,
    support: clipboard.Support,
    display: DisplayEvent,
    file: files.Event,
    pub fn deinit(self: Event) void {
        switch (self) {
            .clipboard => |v| switch (v) {
                .guest_text => |text| text.release(),
                else => {},
            },
            .file => |v| v.deinit(),
            else => {},
        }
    }
};
pub const Host = struct {
    context: *anyopaque,
    /// False is no-byte backpressure. Errors must never be retried implicitly.
    send: *const fn (*anyopaque, u64, agent.Message, *cancel.Token) anyerror!bool,
    /// Called only while clipboard is enabled. Return the host change count.
    write_text: *const fn (*anyopaque, []const u8, *cancel.Token) anyerror!i64,
    /// Consumes the event on every call. It may retain it beyond this callback.
    emit: *const fn (*anyopaque, Event) void,
};
pub const Options = struct { clipboard_enabled: bool = true, maximum_text: usize = 16 * 1024 * 1024 - 4, pending_bytes: usize = 32 * 1024 * 1024, file_limits: files.Limits = .{} };
pub const Pump = enum { idle, blocked, more };
pub const Manager = struct {
    allocator: std.mem.Allocator,
    host: Host,
    state: clipboard.State,
    display: monitors.Coordinator = .{},
    transfers: files.State,
    generation: ?u64 = null,
    pending: [32]clipboard.Action = undefined,
    pending_count: usize = 0,
    pending_bytes: usize = 0,
    maximum_pending_bytes: usize,
    last_support: ?clipboard.Support = null,
    file_cursor: ?u32 = null,
    metrics: @import("agent_metrics.zig").Metrics = .{},
    pub fn init(a: std.mem.Allocator, host: Host, options: Options) Manager {
        return .{ .allocator = a, .host = host, .state = clipboard.State.init(a, @min(options.maximum_text, 16 * 1024 * 1024 - 4), options.clipboard_enabled), .transfers = files.State.init(a, options.file_limits), .maximum_pending_bytes = options.pending_bytes };
    }
    pub fn deinit(self: *Manager) void {
        self.clearPending();
        self.state.deinit();
        self.transfers.deinit();
    }
    fn emit(self: *Manager, event: Event) void {
        self.host.emit(self.host.context, event);
    }
    fn reportSupport(self: *Manager) void {
        const current = self.state.support();
        if (self.last_support) |last| {
            if (std.meta.eql(last, current)) return;
        }
        self.last_support = current;
        self.emit(.{ .support = current });
    }
    fn clearPending(self: *Manager) void {
        for (self.pending[0..self.pending_count]) |action| action.deinit();
        self.pending_count = 0;
        self.pending_bytes = 0;
    }
    fn weight(action: clipboard.Action) usize {
        return switch (action) {
            .send => |v| v.data.bytes().len,
            .write_guest => |v| v.bytes().len,
            .emit => |v| switch (v) {
                .guest_text => |text| text.bytes().len,
                else => 0,
            },
        };
    }
    fn same(left: clipboard.Action, right: clipboard.Action) bool {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .send => |v| v.kind == right.send.kind and v.protocol == right.send.protocol and v.opaque_id == right.send.opaque_id and std.mem.eql(u8, v.data.bytes(), right.send.data.bytes()),
            .write_guest => |v| std.mem.eql(u8, v.bytes(), right.write_guest.bytes()),
            .emit => |v| blk: {
                if (std.meta.activeTag(v) != std.meta.activeTag(right.emit)) break :blk false;
                break :blk switch (v) {
                    .guest_text => |text| std.mem.eql(u8, text.bytes(), right.emit.guest_text.bytes()),
                    .ready, .unavailable => true,
                    .local_offered => |size| size == right.emit.local_offered,
                    .oversized_local => |size| std.meta.eql(size, right.emit.oversized_local),
                };
            },
        };
    }
    /// Consumes actions even on failure. Overflow retires this Agent epoch so a
    /// partially advanced clipboard state can never continue without its effects.
    fn append(self: *Manager, actions: clipboard.Actions) !void {
        var transferred: usize = 0;
        defer for (actions.items[transferred..actions.count]) |action| action.deinit();
        for (actions.items[0..actions.count]) |action| {
            var duplicate = false;
            for (self.pending[0..self.pending_count]) |old| {
                if (same(old, action)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) {
                action.deinit();
                transferred += 1;
                continue;
            }
            const size = weight(action);
            if (self.pending_count == self.pending.len or size > self.maximum_pending_bytes - self.pending_bytes) {
                self.disconnect();
                return error.AgentWorkQueueFull;
            }
            self.pending[self.pending_count] = action;
            self.pending_count += 1;
            self.pending_bytes += size;
            transferred += 1;
        }
    }
    pub fn connect(self: *Manager, generation: u64) !void {
        if (self.generation == generation and self.state.agent_connected) return;
        self.disconnect();
        self.generation = generation;
        try self.append(try self.state.connected());
        self.reportSupport();
    }
    /// Same-session migration preserves negotiated capabilities and transfers.
    /// Fresh-session reconnect must call connect instead. Late old events fail.
    pub fn adoptGeneration(self: *Manager, old: u64, replacement: u64) !void {
        if (self.generation != old or replacement <= old) return error.StaleAgentGeneration;
        self.generation = replacement;
    }
    pub fn disconnect(self: *Manager) void {
        self.clearPending();
        self.display.disconnected();
        self.generation = null;
        self.file_cursor = null;
        while (self.transfers.failFirst(error.AgentUnavailable)) |event| self.emit(.{ .file = event });
        const actions = self.state.disconnected();
        for (actions.items[0..actions.count]) |action| switch (action) {
            .emit => |event| self.emit(.{ .clipboard = event }),
            else => action.deinit(),
        };
        self.reportSupport();
    }
    pub fn receive(self: *Manager, generation: u64, version: u32, kind: u32, data: []const u8) !void {
        if (self.generation != generation) return error.StaleAgentGeneration;
        self.metrics.received(version, kind);
        const decoded = protocol.decodeClipboard(version, kind, data) catch |err| {
            self.metrics.decode_failures +%= 1;
            self.metrics.failure(err);
            return err;
        };
        if (decoded) |command| {
            if (command == .capabilities) self.metrics.peer(command.capabilities.values);
            const actions = self.state.receive(command) catch |err| {
                self.metrics.failure(err);
                return err;
            };
            try self.append(actions);
            self.reportSupport();
            return;
        }
        if (try protocol.decodeMonitorReply(version, kind, data)) |success| {
            if (self.display.reply()) |request| self.emit(.{ .display = if (success) .{ .acknowledged = request } else .{ .rejected = request } }) else self.emit(.{ .display = .{ .failed = .{ .request = null, .reason = error.UnsolicitedMonitorReply } } });
            return;
        }
        if (try protocol.decodeFile(version, kind, data, .{ .chunk = self.transfers.limits.chunk })) |command| switch (command) {
            .status => |status| {
                if (try self.transfers.receive(status)) |event| self.emit(.{ .file = event });
            },
            .start => |v| self.emit(.{ .file = .{ .failed = .{ .id = v.id, .reason = error.UnsupportedGuestFilePayload } } }),
            .data => |v| self.emit(.{ .file = .{ .failed = .{ .id = v.id, .reason = error.UnsupportedGuestFilePayload } } }),
        };
    }
    pub fn localChanged(self: *Manager, change: i64, text: ?[]const u8) !void {
        try self.append(try self.state.localChanged(change, text));
    }
    pub fn localOversized(self: *Manager, change: i64, size: usize) !void {
        try self.append(try self.state.localOversized(change, size));
    }
    pub fn setClipboardEnabled(self: *Manager, enabled: bool) !void {
        if (self.state.enabled == enabled) return;
        // Revoking access also revokes an earlier failed host-write action.
        const actions = try self.state.setEnabled(enabled);
        self.clearPending();
        try self.append(actions);
        self.reportSupport();
    }
    pub fn requestDisplay(self: *Manager, configuration: monitors.Configuration) !void {
        _ = try configuration.encode(self.state.support());
        if (self.state.agent_connected and !self.state.support().monitors) return error.UnsupportedMonitorConfiguration;
        const request = try self.display.queue(configuration);
        self.emit(.{ .display = .{ .queued = request } });
    }
    pub fn queueFile(self: *Manager, file: *source.Source, name: []const u8) !files.Key {
        const event = try self.transfers.queue(file, name, self.state.support());
        const key = event.queued.key;
        self.emit(.{ .file = event });
        return key;
    }
    pub fn cancelFile(self: *Manager, key: files.Key) !void {
        if (try self.transfers.cancelTransfer(key)) |event| self.emit(.{ .file = event });
    }
    fn send(self: *Manager, message: agent.Message, token: *cancel.Token) !bool {
        const generation = self.generation orelse return error.AgentUnavailable;
        return self.host.send(self.host.context, generation, message, token) catch |err| {
            // A failed send can have written a prefix. Retire this epoch and do
            // not replay queued effects on an uncertain transport.
            self.disconnect();
            return err;
        };
    }
    fn pendingOne(self: *Manager, token: *cancel.Token) !bool {
        const action = self.pending[0];
        switch (action) {
            .send => |message| {
                if (message.kind == 6) self.metrics.capability_attempts +%= 1;
                const sent = self.send(message, token) catch |err| {
                    if (message.kind == 6) self.metrics.capability_failures +%= 1;
                    self.metrics.failure(err);
                    return err;
                };
                if (!sent) return false;
                if (message.kind == 6) self.metrics.capability_sent +%= 1;
                self.state.didSend(message.kind);
            },
            .write_guest => |text| {
                if (self.state.enabled) {
                    const change = self.host.write_text(self.host.context, text.bytes(), token) catch |err| {
                        self.metrics.failure(err);
                        return err;
                    };
                    self.state.didWrite(change);
                }
            },
            .emit => {},
        }
        self.pending_bytes -= weight(action);
        std.mem.copyForwards(clipboard.Action, self.pending[0 .. self.pending_count - 1], self.pending[1..self.pending_count]);
        self.pending_count -= 1;
        // Event ownership moves to the host; other actions are now completed.
        switch (action) {
            .emit => |event| self.emit(.{ .clipboard = event }),
            else => action.deinit(),
        }
        return true;
    }
    fn displayOne(self: *Manager, token: *cancel.Token) !bool {
        const request = self.display.next() orelse return false;
        const capabilities = self.state.support();
        if (!capabilities.connected) return false;
        if (!capabilities.monitors) {
            self.display.discardDesired();
            self.emit(.{ .display = .{ .unsupported = request } });
            return true;
        }
        const layout = request.configuration.encode(capabilities) catch |err| {
            self.display.discardDesired();
            self.emit(.{ .display = if (err == error.UnsupportedMonitorConfiguration) .{ .unsupported = request } else .{ .failed = .{ .request = request, .reason = err } } });
            return true;
        };
        if ((layout.sparse or layout.positions) and !capabilities.explicit) return false;
        const message = try layout.message(self.allocator);
        defer message.deinit();
        if (!try self.send(message, token)) return false;
        std.debug.assert(self.display.didSend(request.id));
        self.emit(.{ .display = .{ .sent = request } });
        return true;
    }
    /// Bound a turn to at most maximum_operations. A caller schedules another
    /// turn on .more, and retries .blocked only after tokens/events or its poll.
    pub fn pump(self: *Manager, token: *cancel.Token, maximum_operations: usize) !Pump {
        if (maximum_operations == 0) return error.InvalidLimits;
        if (self.generation == null or !self.state.agent_connected) return .idle;
        var operations: usize = 0;
        while (operations < maximum_operations) : (operations += 1) {
            try token.check();
            if (self.pending_count != 0) {
                if (!try self.pendingOne(token)) return .blocked;
                continue;
            }
            if (try self.displayOne(token)) continue;
            var key = self.transfers.nextKey(self.file_cursor);
            if (key == null) {
                self.file_cursor = null;
                key = self.transfers.nextKey(null);
            }
            if (key == null) return .idle;
            // Scan at most one pass for runnable work. Inactive approvals cannot
            // keep the executor spinning; chunk sends rotate through all jobs.
            var scanned: usize = 0;
            var progressed = false;
            while (scanned < self.transfers.count() and key != null) : (scanned += 1) {
                self.file_cursor = key.?.id;
                const work = try self.transfers.prepare(key.?, self.state.support());
                defer switch (work) {
                    .event => {},
                    else => work.deinit(),
                };
                switch (work) {
                    .idle => {},
                    .event => |event| {
                        self.emit(.{ .file = event });
                        progressed = true;
                    },
                    .read => |read| {
                        try self.transfers.completeRead(read, read.run(self.allocator, token));
                        progressed = true;
                    },
                    .send => |pending| {
                        if (!try self.send(pending.message, token)) return .blocked;
                        if (try self.transfers.completeSend(pending, true)) |event| self.emit(.{ .file = event });
                        progressed = true;
                    },
                }
                if (progressed) break;
                key = self.transfers.nextKey(self.file_cursor);
                if (key == null) {
                    self.file_cursor = null;
                    key = self.transfers.nextKey(null);
                }
            }
            if (!progressed) return if (self.display.next() != null) .blocked else .idle;
        }
        return .more;
    }
};
