//! Typed Main ABI. Main/Agent parsing and scheduling remain entirely in Zig.
const std = @import("std");
const session = @import("session.zig");
const main = @import("main_channel.zig");
const agent = @import("agent.zig");
const wire = @import("bytes.zig");
const clock = @import("clock.zig");
const network = @import("network_abi.zig");
const a = std.heap.c_allocator;
const Handle = struct { value: main.Main };
const Event = union(enum) { main: main.Event, channel: ?wire.Slice };
pub const Info = extern struct { session_id: u32, multimedia_time: u32, supported_mouse_modes: u32, current_mouse_mode: u32, agent_connected: u32 };
pub const Metadata = extern struct { kind: u16, wire_kind: u16, protocol: u32, value: u32, auxiliary: u32, opaque_id: u64 };
fn status(err: anyerror) c_int {
    return switch (err) {
        error.MigrationRequested => -44,
        else => network.status(err),
    };
}
pub export fn spice_zig_main_create(connection: ?*session.Connection) ?*Handle {
    const c = connection orelse return null;
    if (c.key.kind != 1) return null;
    const h = a.create(Handle) catch return null;
    h.* = .{ .value = main.Main.init(a, &c.channel, .{ .context = &c.owner.clock, .reset = clock.Clock.resetCallback }) };
    return h;
}
pub export fn spice_zig_main_cancel(self: ?*Handle) void {
    if (self) |h| h.value.cancel();
}
pub export fn spice_zig_main_destroy(self: ?*Handle) void {
    if (self) |h| {
        h.value.deinit();
        a.destroy(h);
    }
}
pub export fn spice_zig_main_bootstrap(self: ?*Handle, output: ?*?*main.Bootstrap) c_int {
    const out = output orelse return -1;
    out.* = null;
    const h = self orelse return -1;
    const result = a.create(main.Bootstrap) catch return -2;
    result.* = h.value.bootstrap() catch |err| {
        a.destroy(result);
        return status(err);
    };
    out.* = result;
    return 0;
}
pub export fn spice_zig_main_bootstrap_destroy(self: ?*main.Bootstrap) void {
    if (self) |h| {
        h.deinit();
        a.destroy(h);
    }
}
pub export fn spice_zig_main_bootstrap_info(self: ?*const main.Bootstrap, output: ?*Info) c_int {
    const h = self orelse return -1;
    const out = output orelse return -1;
    out.* = .{ .session_id = h.session_id, .multimedia_time = h.multimedia_time, .supported_mouse_modes = h.mouse.supported, .current_mouse_mode = h.mouse.current, .agent_connected = @intFromBool(h.agent_connected) };
    return 0;
}
pub export fn spice_zig_main_bootstrap_channels(self: ?*const main.Bootstrap, count: ?*usize) ?[*]const u8 {
    const out = count orelse return null;
    out.* = 0;
    const h = self orelse return null;
    out.* = h.channels.len;
    return @ptrCast(h.channels.ptr);
}
pub export fn spice_zig_main_next(self: ?*Handle, output: ?*?*Event) c_int {
    const out = output orelse return -1;
    out.* = null;
    const h = self orelse return -1;
    const e = a.create(Event) catch return -2;
    const event = h.value.next() catch |err| {
        a.destroy(e);
        return status(err);
    };
    if (event) |value| {
        e.* = .{ .main = value };
        out.* = e;
        return 1;
    }
    a.destroy(e);
    return 0;
}
pub export fn spice_zig_main_take_migration(self: ?*Handle, output: ?*?*Event) c_int {
    const out = output orelse return -1;
    out.* = null;
    const h = self orelse return -1;
    const e = a.create(Event) catch return -2;
    e.* = .{ .channel = h.value.takeMigration() catch |err| {
        a.destroy(e);
        return status(err);
    } };
    out.* = e;
    return 0;
}
pub export fn spice_zig_main_event_destroy(self: ?*Event) void {
    if (self) |e| {
        switch (e.*) {
            .main => |m| m.deinit(),
            .channel => |m| {
                if (m) |data| data.release();
            },
        }
        a.destroy(e);
    }
}
pub export fn spice_zig_main_event_data(self: ?*const Event, size: ?*usize) ?[*]const u8 {
    const out = size orelse return null;
    out.* = 0;
    const e = self orelse return null;
    const bytes: ?wire.Slice = switch (e.*) {
        .channel => |m| m,
        .main => |m| switch (m) {
            .agent_message => |v| v.data,
            .migration => |v| v.storage,
            else => null,
        },
    };
    if (bytes) |data| {
        out.* = data.bytes().len;
        return data.bytes().ptr;
    }
    return null;
}
pub export fn spice_zig_main_event_metadata(self: ?*const Event, output: ?*Metadata) c_int {
    const out = output orelse return -1;
    const e = self orelse return -1;
    out.* = std.mem.zeroes(Metadata);
    switch (e.*) {
        .channel => out.kind = 6,
        .main => |event| switch (event) {
            .mouse => |m| {
                out.kind = 1;
                out.value = m.supported;
                out.auxiliary = m.current;
            },
            .agent_connected => out.kind = 2,
            .agent_disconnected => |code| {
                out.kind = 3;
                out.value = code.code;
            },
            .agent_message => |m| {
                out.kind = 4;
                out.protocol = m.protocol;
                out.value = m.kind;
                out.opaque_id = m.opaque_id;
            },
            .migration => |m| {
                out.kind = 5;
                out.wire_kind = switch (m.command) {
                    .begin => 101,
                    .cancel => 102,
                    .switch_host => 111,
                    .end => 112,
                    .begin_seamless => 116,
                    .accepted => 117,
                    .rejected => 118,
                };
            },
        },
    }
    return 0;
}
pub export fn spice_zig_agent_send_token_create() ?*agent.SendToken {
    const token = a.create(agent.SendToken) catch return null;
    token.* = .{};
    return token;
}
pub export fn spice_zig_agent_send_token_destroy(self: ?*agent.SendToken) void {
    if (self) |token| a.destroy(token);
}
pub export fn spice_zig_agent_send_cancel(self: ?*Handle, token: ?*agent.SendToken) void {
    if (self) |h| {
        if (token) |t| h.value.sender.cancelSend(t);
    }
}
pub export fn spice_zig_agent_send(self: ?*Handle, protocol: u32, kind: u32, opaque_id: u64, data: ?[*]const u8, size: usize, token: ?*agent.SendToken) c_int {
    const h = self orelse return -1;
    const t = token orelse return -1;
    if (size != 0 and data == null) return -1;
    const sent = h.value.sender.send(protocol, kind, opaque_id, if (data) |p| p[0..size] else &.{}, t) catch |err| return status(err);
    return @intFromBool(sent);
}
