//! Agent manager bound to the real supervisor. Session identity (fresh guest)
//! and Agent incarnation are fenced independently of transport migration.
//! All methods except external Token cancellation have one serialized caller.
const std = @import("std");
const core = @import("agent_manager.zig");
const agent = @import("agent.zig");
const cancel = @import("cancel.zig");
const supervisor = @import("supervisor.zig");
pub fn Binding(comptime Runtime: type) type {
    return struct {
        const Self = @This();
        pub const Host = struct { context: *anyopaque, check: ?*const fn (*anyopaque) anyerror!void = null, write_text: *const fn (*anyopaque, []const u8, *cancel.Token) anyerror!i64, emit: *const fn (*anyopaque, core.Event) void };
        allocator: std.mem.Allocator,
        runtime: *Runtime,
        manager: core.Manager,
        host: Host,
        identity: ?supervisor.AgentEpoch = null,
        logical_generation: u64 = 0,
        pub fn create(a: std.mem.Allocator, runtime: *Runtime, host: Host, options: core.Options) !*Self {
            const self = try a.create(Self);
            self.* = .{ .allocator = a, .runtime = runtime, .host = host, .manager = undefined };
            self.manager = core.Manager.init(a, .{ .context = self, .send = send, .write_text = writeText, .emit = emit }, options);
            errdefer {
                self.manager.deinit();
                a.destroy(self);
            }
            try self.bootstrap();
            return self;
        }
        pub fn destroy(self: *Self) void {
            self.manager.deinit();
            self.allocator.destroy(self);
        }
        fn send(p: *anyopaque, generation: u64, message: agent.Message, token: *cancel.Token) !bool {
            const self: *Self = @ptrCast(@alignCast(p));
            if (generation != self.logical_generation) return error.StaleAgentGeneration;
            if (self.host.check) |check| try check(self.host.context);
            const identity = self.identity orelse return error.AgentUnavailable;
            return self.runtime.sendAgentAt(identity, message.protocol, message.kind, message.opaque_id, message.data.bytes(), token) catch |err| switch (err) {
                error.InvalidState => false,
                else => err,
            };
        }
        fn writeText(p: *anyopaque, text: []const u8, token: *cancel.Token) !i64 {
            const self: *Self = @ptrCast(@alignCast(p));
            return self.host.write_text(self.host.context, text, token);
        }
        fn emit(p: *anyopaque, event: core.Event) void {
            const self: *Self = @ptrCast(@alignCast(p));
            self.host.emit(self.host.context, event);
        }
        fn update(self: *Self, identity: supervisor.AgentEpoch, connected: bool) !bool {
            if (self.identity) |old| {
                if (identity.session < old.session or (identity.session == old.session and identity.agent < old.agent)) return false;
                if (std.meta.eql(old, identity)) return true;
            }
            const generation = try std.math.add(u64, self.logical_generation, 1);
            self.manager.disconnect();
            if (connected) try self.manager.connect(generation);
            self.logical_generation = generation;
            self.identity = identity;
            return true;
        }
        fn bootstrap(self: *Self) !void {
            self.runtime.mutex.lock();
            const group = self.runtime.active;
            const available = self.runtime.phase == .ready and !self.runtime.stopping and group != null;
            const initial = if (available) group.?.bootstrap else null;
            const lifecycle = self.runtime.lifecycle;
            self.runtime.mutex.unlock();
            const info = initial orelse {
                self.manager.disconnect();
                return;
            };
            _ = try self.update(.{ .session = lifecycle, .agent = info.agent_epoch }, info.agent_connected);
        }
        /// Borrows an event. Never retains the large unrelated display/audio payloads.
        pub fn observe(self: *Self, event: Runtime.Event) !void {
            switch (event.value) {
                .connected => try self.bootstrap(),
                .failed, .disconnected => {
                    self.manager.disconnect();
                },
                .migration => |migration| {
                    if (migration.kind == .completed and migration.offer.mode == .switch_host) try self.bootstrap();
                },
                .main => |message| switch (message) {
                    .agent_connected => |epoch| {
                        _ = try self.update(.{ .session = event.lifecycle, .agent = epoch }, true);
                    },
                    .agent_disconnected => |disconnected| {
                        _ = try self.update(.{ .session = event.lifecycle, .agent = disconnected.epoch }, false);
                    },
                    .agent_message => |m| {
                        if (!try self.update(.{ .session = event.lifecycle, .agent = m.epoch }, true)) return;
                        try self.manager.receive(self.logical_generation, m.protocol, m.kind, m.data.bytes());
                    },
                    else => {},
                },
                else => {},
            }
        }
    };
}
