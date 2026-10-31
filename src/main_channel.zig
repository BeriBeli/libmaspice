//! Main bootstrap/control and Agent stream. One receive/control worker; Agent
//! producers use Sender's FIFO gate. Events own data beyond Main/session life.
//! Connection replacement is performed only by a quiescent receive worker;
//! active Agent messages retain their captured old connection until drained.
const std = @import("std");
const wire = @import("bytes.zig");
const p = @import("generated.zig");
const channels = @import("channel.zig");
const barriers = @import("barrier.zig");
const agent = @import("agent.zig");
const migration = @import("migration.zig");
pub const Mouse = struct { supported: u32, current: u32 };
pub const Event = union(enum) {
    mouse: Mouse,
    agent_connected: u64,
    agent_disconnected: struct { code: u32, epoch: u64 },
    agent_message: agent.Message,
    migration: struct { command: migration.Command, storage: wire.Slice },
    pub fn deinit(self: Event) void {
        switch (self) {
            .agent_message => |m| m.deinit(),
            .migration => |m| m.storage.release(),
            else => {},
        }
    }
    fn dataSize(self: Event) usize {
        return switch (self) {
            .agent_message => |m| m.data.bytes().len,
            else => 0,
        };
    }
};
pub const Bootstrap = struct {
    allocator: std.mem.Allocator,
    session_id: u32,
    multimedia_time: u32,
    mouse: Mouse,
    agent_connected: bool,
    agent_epoch: u64 = 0,
    channels: []barriers.Key,
    pub fn deinit(self: Bootstrap) void {
        self.allocator.free(self.channels);
    }
};
/// A real clock owner is injected. Main delivers every server reset (initial,
/// bootstrap-time and runtime); the callback must not reenter Main.
pub const Clock = struct { context: *anyopaque, reset: *const fn (*anyopaque, u32) void };
pub const Main = struct {
    allocator: std.mem.Allocator,
    connection: *channels.Channel,
    clock: Clock,
    decoder: agent.Decoder,
    sender: agent.Sender,
    server_window: u32 = 8,
    server_tokens: u32 = 0,
    agent_connected: bool = false,
    bootstrapped: bool = false,
    initialized: bool = false,
    multimedia_time: u32 = 0,
    mouse: Mouse = .{ .supported = 0, .current = 0 },
    last_requested: ?Mouse = null,
    pending: std.ArrayList(Event) = .empty,
    pending_bytes: usize = 0,
    migration_requested: bool = false,
    migration_data: ?wire.Slice = null,
    pub fn init(allocator: std.mem.Allocator, connection: *channels.Channel, clock: Clock) Main {
        return .{ .allocator = allocator, .connection = connection, .clock = clock, .decoder = .{ .allocator = allocator }, .sender = .{ .allocator = allocator, .connection = connection } };
    }
    pub fn deinit(self: *Main) void {
        if (self.migration_data) |data| data.release();
        self.sender.deinit();
        self.decoder.deinit();
        for (self.pending.items) |e| e.deinit();
        self.pending.deinit(self.allocator);
    }
    pub fn cancel(self: *Main) void {
        self.sender.cancel();
    }
    pub fn replace(self: *Main, replacement: *channels.Channel) !*channels.Channel {
        const previous = try self.sender.rebind(replacement);
        self.connection = replacement;
        self.last_requested = null;
        return previous;
    }
    fn sendGenerated(self: *Main, message: anytype) !void {
        var output: wire.Writer = .{ .allocator = self.allocator, .limit = 64 * 1024 * 1024 };
        defer output.deinit();
        try message.encode(&output);
        try self.connection.send(@TypeOf(message).message_id.?, output.bytes.items);
    }
    fn sendWord(self: *Main, kind: u16, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.connection.send(kind, &bytes);
    }
    fn setTime(self: *Main, time: u32) void {
        self.multimedia_time = time;
        self.clock.reset(self.clock.context, time);
    }
    fn setMouse(self: *Main, mouse: Mouse) !void {
        self.mouse = mouse;
        if (mouse.current == 2 or mouse.supported & 2 == 0) {
            self.last_requested = null;
            return;
        }
        if (self.last_requested) |last| {
            if (std.meta.eql(last, mouse)) return;
        }
        try self.sendGenerated(p.SpiceMsgcMainMouseModeRequest{ .mode = 2 });
        self.last_requested = mouse;
    }
    fn startAgent(self: *Main, tokens: u32) !void {
        if (self.agent_connected) return error.InvalidAgentState;
        const window = @max(self.server_window, 1);
        try self.sendWord(106, window);
        try self.sender.start(tokens);
        self.server_tokens = window;
        self.agent_connected = true;
        self.decoder.reset();
    }
    fn queue(self: *Main, event: Event) !void {
        errdefer event.deinit();
        if (self.pending.items.len >= 64 or event.dataSize() > self.decoder.limits.data - self.pending_bytes) return error.MessageTooLarge;
        try self.pending.append(self.allocator, event);
        self.pending_bytes += event.dataSize();
    }
    fn pop(self: *Main) ?Event {
        if (self.pending.items.len == 0) return null;
        const event = self.pending.orderedRemove(0);
        self.pending_bytes -= event.dataSize();
        return event;
    }
    fn receive(self: *Main) !channels.Delivery {
        if (self.migration_requested) return error.MigrationRequested;
        const event = try self.connection.receive();
        return switch (event) {
            .message => |message| message,
            .migration => |data| {
                if (self.migration_data) |old| old.release();
                self.migration_requested = true;
                self.migration_data = data;
                return error.MigrationRequested;
            },
        };
    }
    /// Transfers optional channel migration bytes to the session handoff owner.
    pub fn takeMigration(self: *Main) !?wire.Slice {
        if (!self.migration_requested) return error.InvalidState;
        self.migration_requested = false;
        const data = self.migration_data;
        self.migration_data = null;
        return data;
    }
    fn handleAgent(self: *Main, message: channels.Delivery) !bool {
        const bytes = message.body.bytes();
        var reader = try wire.Reader.init(bytes, 0);
        switch (message.kind) {
            107, 115 => {
                const tokens: u32 = if (message.kind == 115) try reader.read(u32) else 0;
                try reader.finish();
                try self.startAgent(tokens);
                try self.queue(.{ .agent_connected = self.sender.epoch() });
            },
            108 => {
                const code = try reader.read(u32);
                try reader.finish();
                if (!self.agent_connected) return error.InvalidAgentState;
                self.agent_connected = false;
                self.server_tokens = 0;
                self.sender.reset();
                self.decoder.reset();
                try self.queue(.{ .agent_disconnected = .{ .code = code, .epoch = self.sender.epoch() } });
            },
            110 => {
                const tokens = try reader.read(u32);
                try reader.finish();
                try self.sender.addTokens(tokens);
            },
            109 => {
                if (!self.agent_connected or self.server_tokens == 0) return error.InvalidAgentState;
                self.server_tokens -= 1;
                const decoded = try self.decoder.append(bytes);
                defer decoded.deinit();
                try self.sendWord(108, 1);
                self.server_tokens += 1;
                for (decoded.items) |message_value| {
                    var retained = message_value;
                    retained.data = retained.data.clone();
                    retained.epoch = self.sender.epoch();
                    try self.queue(.{ .agent_message = retained });
                }
            },
            else => return false,
        }
        return true;
    }
    fn control(self: *Main, message: channels.Delivery, during_bootstrap: bool) !void {
        const bytes = message.body.bytes();
        if (try self.handleAgent(message)) return;
        if (try migration.decode(message.kind, bytes)) |command| {
            if (during_bootstrap) return error.UnexpectedMigration;
            try self.queue(.{ .migration = .{ .command = command, .storage = message.body.clone() } });
            return;
        }
        switch (message.kind) {
            3 => {
                const ack = try p.SpiceMsgSetAck.decodeExact(bytes);
                self.connection.configureAck(ack.generation, ack.window);
                try self.sendGenerated(p.SpiceMsgcAckSync{ .generation = ack.generation });
            },
            4 => {
                var reader = try wire.Reader.init(bytes, 0);
                const ping = try p.SpiceMsgPing.decode(&reader);
                try self.sendGenerated(p.SpiceMsgcPong{ .id = ping.id, .time = ping.time });
            },
            6 => {
                _ = try p.SpiceMsgDisconnect.decodeExact(bytes);
                return error.ConnectionClosed;
            },
            103 => return error.DuplicateMainInit,
            105 => {
                const mode = try p.SpiceMsgMainMouseMode.decodeExact(bytes);
                try self.setMouse(.{ .supported = mode.supportedModes, .current = mode.currentMode });
                if (!during_bootstrap) try self.queue(.{ .mouse = self.mouse });
            },
            106 => {
                const time = try p.SpiceMsgMainMultimediaTime.decodeExact(bytes);
                self.setTime(time.multimediaTime);
            },
            else => {}, // Existing Main contract ignores unknown extension messages.
        }
    }
    pub fn bootstrap(self: *Main) !Bootstrap {
        if (self.initialized) return error.InvalidState;
        errdefer if (!self.migration_requested) self.cancel();
        const first = try self.receive();
        defer first.deinit();
        if (first.kind != 103) return error.ExpectedMainInit;
        const initial = try p.SpiceMsgMainInit.decodeExact(first.body.bytes());
        self.initialized = true;
        self.setTime(initial.multimediaTime);
        try self.setMouse(.{ .supported = initial.supportedMouseModes, .current = initial.currentMouseMode });
        if (initial.agentConnected != 0) try self.startAgent(initial.agentTokens);
        try self.sendGenerated(p.SpiceMsgcMainAttachChannels{});
        try self.connection.complete();
        while (true) {
            const message = try self.receive();
            defer message.deinit();
            if (message.kind == 104) {
                const list = try p.SpiceMsgMainChannelsList.decodeExact(message.body.bytes());
                if (list.channels.count() > 65536) return error.TooManyChannels;
                const keys = try self.allocator.alloc(barriers.Key, list.channels.count());
                errdefer self.allocator.free(keys);
                for (keys, 0..) |*key, index| {
                    const value = try list.channels.at(index);
                    key.* = .{ .kind = value.kind, .id = value.id };
                }
                try self.connection.complete();
                self.bootstrapped = true;
                return .{ .allocator = self.allocator, .session_id = initial.sessionID, .multimedia_time = self.multimedia_time, .mouse = self.mouse, .agent_connected = self.agent_connected, .agent_epoch = self.sender.epoch(), .channels = keys };
            }
            try self.control(message, true);
            try self.connection.complete();
        }
    }
    /// Null is a handled control message. Every non-null event transfers ownership.
    pub fn next(self: *Main) !?Event {
        if (!self.bootstrapped) return error.InvalidState;
        errdefer if (!self.migration_requested) self.cancel();
        if (self.pop()) |event| return event;
        const message = try self.receive();
        defer message.deinit();
        try self.control(message, false);
        try self.connection.complete();
        return self.pop();
    }
    pub fn sendMigration(self: *Main, reply: migration.Reply) !void {
        var output: wire.Writer = .{ .allocator = self.allocator, .limit = 4 };
        defer output.deinit();
        const kind = try migration.encode(reply, &output);
        try self.connection.send(kind, output.bytes.items);
    }
    pub fn negotiateSeamless(self: *Main, source_version: u32) !bool {
        if (self.initialized) return error.InvalidState;
        errdefer if (!self.migration_requested) self.cancel();
        try self.sendMigration(.{ .do_seamless = source_version });
        const message = try self.receive();
        defer message.deinit();
        const command = (try migration.decode(message.kind, message.body.bytes())) orelse return error.UnexpectedMigration;
        const accepted = switch (command) {
            .accepted => true,
            .rejected => false,
            else => return error.UnexpectedMigration,
        };
        try self.connection.complete();
        return accepted;
    }
};
