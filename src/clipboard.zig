//! Serialized clipboard negotiation and ownership policy. No host pasteboard
//! access occurs here. Actions own all text/messages and may outlive the state.
//! Call didSend only after transport success; didWrite after host write success.
const std = @import("std");
const wire = @import("bytes.zig");
const protocol = @import("agent_services_wire.zig");
const agent = @import("agent.zig");
pub const Event = union(enum) { ready, unavailable, guest_text: wire.Slice, local_offered: usize, oversized_local: struct { size: usize, maximum: usize } };
pub const Action = union(enum) {
    send: agent.Message,
    write_guest: wire.Slice,
    emit: Event,
    pub fn deinit(self: Action) void {
        switch (self) {
            .send => |v| v.deinit(),
            .write_guest => |v| v.release(),
            .emit => |v| switch (v) {
                .guest_text => |data| data.release(),
                else => {},
            },
        }
    }
};
pub const Actions = struct {
    items: [4]Action = undefined,
    count: usize = 0,
    fn append(self: *Actions, action: Action) void {
        std.debug.assert(self.count < self.items.len);
        self.items[self.count] = action;
        self.count += 1;
    }
    pub fn deinit(self: Actions) void {
        for (self.items[0..self.count]) |v| v.deinit();
    }
};
pub const Support = struct { connected: bool, explicit: bool, monitors: bool, sparse: bool, positions: bool, file_state: bool, files: bool, detailed_errors: bool };
pub const State = struct {
    allocator: std.mem.Allocator,
    maximum_text: usize,
    enabled: bool = true,
    agent_connected: bool = false,
    announced: bool = false,
    peer: ?protocol.Capabilities = null,
    was_ready: bool = false,
    local_text: ?wire.Slice = null,
    local_grab: bool = false,
    guest_grab: bool = false,
    awaiting_data: bool = false,
    last_change: ?i64 = null,
    pub fn init(a: std.mem.Allocator, maximum: usize, enabled: bool) State {
        return .{ .allocator = a, .maximum_text = maximum, .enabled = enabled };
    }
    pub fn deinit(self: *State) void {
        self.reset();
    }
    fn clearText(self: *State) void {
        if (self.local_text) |v| v.release();
        self.local_text = null;
    }
    fn reset(self: *State) void {
        self.clearText();
        self.agent_connected = false;
        self.announced = false;
        self.peer = null;
        self.was_ready = false;
        self.local_grab = false;
        self.guest_grab = false;
        self.awaiting_data = false;
        self.last_change = null;
    }
    pub fn ready(self: State) bool {
        return self.enabled and self.agent_connected and if (self.peer) |caps| caps.contains(5) else false;
    }
    pub fn support(self: State) Support {
        return .{ .connected = self.agent_connected, .explicit = self.peer != null, .monitors = self.agent_connected and if (self.peer) |caps| caps.contains(1) and caps.contains(2) else true, .sparse = if (self.peer) |caps| caps.contains(7) else false, .positions = if (self.peer) |caps| caps.contains(12) else false, .file_state = self.agent_connected and self.peer != null, .files = self.agent_connected and if (self.peer) |caps| !caps.contains(13) else false, .detailed_errors = if (self.peer) |caps| caps.contains(14) else false };
    }
    fn send(self: State, result: *Actions, command: protocol.Clipboard) !void {
        result.append(.{ .send = try protocol.encodeClipboard(self.allocator, command, 0) });
    }
    fn announce(self: State, result: *Actions, reply: bool, enabled: bool) !void {
        try self.send(result, .{ .capabilities = .{ .reply = reply, .values = protocol.Capabilities.desktop(enabled) } });
    }
    pub fn connected(self: *State) !Actions {
        var result: Actions = .{};
        try self.announce(&result, true, self.enabled);
        self.reset();
        self.agent_connected = true;
        return result;
    }
    pub fn disconnected(self: *State) Actions {
        var result: Actions = .{};
        if (self.was_ready) result.append(.{ .emit = .unavailable });
        self.reset();
        return result;
    }
    pub fn announcementIfNeeded(self: State) !Actions {
        var result: Actions = .{};
        if (self.agent_connected and !self.announced) try self.announce(&result, true, self.enabled);
        return result;
    }
    pub fn didSend(self: *State, kind: u32) void {
        if (kind == 6) self.announced = true;
    }
    pub fn setEnabled(self: *State, enabled: bool) !Actions {
        var result: Actions = .{};
        errdefer result.deinit();
        if (self.enabled == enabled) return result;
        if (!enabled and self.ready() and self.local_grab) try self.send(&result, .release);
        if (self.agent_connected) try self.announce(&result, true, enabled);
        const unavailable = !enabled and self.was_ready;
        self.enabled = enabled;
        self.announced = false;
        self.clearText();
        self.local_grab = false;
        self.guest_grab = false;
        self.awaiting_data = false;
        self.last_change = null;
        if (unavailable) {
            self.was_ready = false;
            result.append(.{ .emit = .unavailable });
        } else if (enabled and self.ready() and !self.was_ready) {
            self.was_ready = true;
            result.append(.{ .emit = .ready });
        }
        return result;
    }
    fn requireReady(self: State) !void {
        if (!self.ready()) return error.ClipboardNotReady;
    }
    pub fn receive(self: *State, command: protocol.Clipboard) !Actions {
        if (!self.agent_connected) return error.AgentDisconnected;
        var result: Actions = .{};
        errdefer result.deinit();
        switch (command) {
            .capabilities => |v| {
                if (v.values.count > 16) return error.InvalidSize;
                const is_ready = self.enabled and v.values.contains(5);
                if (v.reply) try self.announce(&result, false, self.enabled);
                if (is_ready != self.was_ready) result.append(.{ .emit = if (is_ready) .ready else .unavailable });
                if (is_ready and !self.local_grab) if (self.local_text) |text| {
                    try self.send(&result, .{ .grab = protocol.Types.utf8() });
                    result.append(.{ .emit = .{ .local_offered = text.bytes().len } });
                };
                self.peer = v.values;
                self.was_ready = is_ready;
                if (is_ready and self.local_text != null) self.local_grab = true;
            },
            .grab => |types| {
                if (!self.enabled) return result;
                try self.requireReady();
                if (types.count == 0 or types.count > 64) return error.InvalidSize;
                if (types.hasText()) try self.send(&result, .{ .request = 1 });
                self.clearText();
                self.local_grab = false;
                self.guest_grab = true;
                self.awaiting_data = types.hasText();
            },
            .request => |kind| {
                if (!self.enabled) return result;
                try self.requireReady();
                if (kind == 1 and self.local_grab and self.local_text != null) try self.send(&result, .{ .data = .{ .kind = 1, .bytes = self.local_text.?.bytes() } }) else try self.send(&result, .{ .data = .{ .kind = 0, .bytes = &.{} } });
            },
            .data => |data| {
                if (!self.enabled) return result;
                try self.requireReady();
                if (!self.awaiting_data or !self.guest_grab) return error.UnsolicitedClipboardData;
                // Protocol rejection consumes the pending request, matching Swift.
                if (data.kind == 0) {
                    self.awaiting_data = false;
                    return result;
                }
                if (data.kind != 1) {
                    self.awaiting_data = false;
                    return error.UnexpectedClipboardType;
                }
                if (data.bytes.len > self.maximum_text) {
                    self.awaiting_data = false;
                    return error.OversizedGuestText;
                }
                if (!std.unicode.utf8ValidateSlice(data.bytes)) {
                    self.awaiting_data = false;
                    return error.InvalidUTF8;
                }
                // Foundation String(data:encoding:.utf8) consumes one leading BOM.
                const utf8 = if (std.mem.startsWith(u8, data.bytes, "\xef\xbb\xbf")) data.bytes[3..] else data.bytes;
                const text = try wire.Slice.copy(self.allocator, utf8);
                result.append(.{ .write_guest = text });
                result.append(.{ .emit = .{ .guest_text = text.clone() } });
                self.awaiting_data = false;
            },
            .release => {
                if (!self.enabled) return result;
                try self.requireReady();
                self.guest_grab = false;
                self.awaiting_data = false;
            },
        }
        return result;
    }
    pub fn localChanged(self: *State, change: i64, text: ?[]const u8) !Actions {
        var result: Actions = .{};
        errdefer result.deinit();
        if (!self.enabled or self.last_change == change) return result;
        var copy: ?wire.Slice = null;
        errdefer if (copy) |v| v.release();
        if (text) |bytes| {
            if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUTF8;
            if (bytes.len > self.maximum_text) return self.localOversized(change, bytes.len);
            {
                copy = try wire.Slice.copy(self.allocator, bytes);
                if (self.ready()) {
                    try self.send(&result, .{ .grab = protocol.Types.utf8() });
                    result.append(.{ .emit = .{ .local_offered = bytes.len } });
                }
            }
        } else if (self.ready() and self.local_grab) try self.send(&result, .release);
        self.last_change = change;
        self.guest_grab = false;
        self.awaiting_data = false;
        self.clearText();
        self.local_text = copy;
        self.local_grab = copy != null and self.ready();
        return result;
    }
    /// Native snapshots may report size without allocating an oversized payload.
    pub fn localOversized(self: *State, change: i64, size: usize) !Actions {
        if (size <= self.maximum_text) return error.InvalidSize;
        var result: Actions = .{};
        errdefer result.deinit();
        if (!self.enabled or self.last_change == change) return result;
        if (self.ready() and self.local_grab) try self.send(&result, .release);
        result.append(.{ .emit = .{ .oversized_local = .{ .size = size, .maximum = self.maximum_text } } });
        self.last_change = change;
        self.guest_grab = false;
        self.awaiting_data = false;
        self.clearText();
        self.local_grab = false;
        return result;
    }
    pub fn didWrite(self: *State, change: i64) void {
        self.last_change = change;
        self.clearText();
        self.local_grab = false;
    }
};
