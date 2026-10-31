const std = @import("std");
const s = @import("spice");
const p = s.agent_services_wire;
const a = std.heap.c_allocator;
pub export fn service_parse(protocol: u32, kind: u32, bytes: [*]const u8, len: usize) c_int {
    const data = bytes[0..len];
    if (p.decodeClipboard(protocol, kind, data) catch return -1) |_| return 1;
    if (p.decodeFile(protocol, kind, data, .{}) catch return -1) |_| return 2;
    if (p.decodeMonitorReply(protocol, kind, data) catch return -1) |_| return 3;
    return 0;
}
pub export fn service_filename(bytes: [*]const u8, len: usize, output: [*]u8, capacity: usize) isize {
    const m = p.encodeFileStart(a, 7, bytes[0..len], 123, .{}) catch return -1;
    defer m.deinit();
    if (m.data.bytes().len > capacity) return -2;
    @memcpy(output[0..m.data.bytes().len], m.data.bytes());
    return @intCast(m.data.bytes().len);
}
pub export fn clipboard_create() *s.clipboard.State {
    const state = a.create(s.clipboard.State) catch @panic("allocation");
    state.* = s.clipboard.State.init(a, 32, true);
    return state;
}
pub export fn clipboard_destroy(state: *s.clipboard.State) void {
    state.deinit();
    a.destroy(state);
}
fn act(state: *s.clipboard.State, op: u32, value: i64, kind: u32, data: []const u8) !s.clipboard.Actions {
    return switch (op) {
        0 => state.connected(),
        1 => state.disconnected(),
        2 => state.setEnabled(value != 0),
        3 => blk: {
            state.didSend(kind);
            break :blk .{};
        },
        4 => if (try p.decodeClipboard(@intCast(value), kind, data)) |command| state.receive(command) else .{},
        5 => state.localChanged(value, if (kind == 0) null else data),
        8 => state.localOversized(value, data.len),
        6 => blk: {
            state.didWrite(value);
            break :blk .{};
        },
        7 => state.announcementIfNeeded(),
        else => error.InvalidOperation,
    };
}
fn errorCode(err: anyerror) i32 {
    return switch (err) {
        error.AgentDisconnected => -2,
        error.ClipboardNotReady => -3,
        error.UnsolicitedClipboardData => -4,
        error.UnexpectedClipboardType => -5,
        error.OversizedGuestText => -6,
        error.InvalidUTF8 => -7,
        else => -1,
    };
}
fn payload(w: *s.bytes.Writer, kind: u32, data: []const u8) !void {
    try w.write(u32, kind);
    try w.write(u32, @intCast(data.len));
    try w.append(data);
}
fn number(w: *s.bytes.Writer, kind: u32, value: usize) !void {
    try w.write(u32, kind);
    try w.write(u32, 8);
    try w.write(u64, value);
}
fn step(state: *s.clipboard.State, op: u32, value: i64, kind: u32, data: []const u8, w: *s.bytes.Writer) !void {
    var result: s.clipboard.Actions = .{};
    var status: i32 = 0;
    result = act(state, op, value, kind, data) catch |err| blk: {
        status = errorCode(err);
        break :blk .{};
    };
    defer result.deinit();
    try w.write(i32, status);
    const support = state.support();
    var bits: u32 = 0;
    inline for (.{ state.ready(), support.connected, support.explicit, support.monitors, support.sparse, support.positions, support.file_state, support.files, support.detailed_errors }, 0..) |v, i| {
        if (v) bits |= @as(u32, 1) << i;
    }
    try w.write(u32, bits);
    for (result.items[0..result.count]) |action| switch (action) {
        .send => |m| try payload(w, m.kind, m.data.bytes()),
        .write_guest => |v| try payload(w, 100, v.bytes()),
        .emit => |v| switch (v) {
            .ready => try payload(w, 101, &.{}),
            .unavailable => try payload(w, 102, &.{}),
            .guest_text => |text| try payload(w, 103, text.bytes()),
            .local_offered => |size| try number(w, 104, size),
            .oversized_local => |size| {
                try w.write(u32, 105);
                try w.write(u32, 16);
                try w.write(u64, size.size);
                try w.write(u64, size.maximum);
            },
        },
    };
}
pub export fn clipboard_step(state: *s.clipboard.State, op: u32, value: i64, kind: u32, bytes: [*]const u8, len: usize, output: [*]u8, capacity: usize) isize {
    var w: s.bytes.Writer = .{ .allocator = a, .limit = capacity };
    defer w.deinit();
    step(state, op, value, kind, bytes[0..len], &w) catch return -1;
    @memcpy(output[0..w.bytes.items.len], w.bytes.items);
    return @intCast(w.bytes.items.len);
}

pub export fn service_layout(explicit: u8, caps: u32, bytes: [*]const u8, len: usize, output: [*]u8, capacity: usize) isize {
    var r = s.bytes.Reader.init(bytes[0..len], 0) catch return -1;
    const count = r.read(u32) catch return -1;
    if (count == 0 or count > 256) return -1;
    var entries: [256]s.monitor_config.Monitor = undefined;
    for (entries[0..count]) |*m| {
        m.* = .{ .id = r.read(i64) catch return -1, .x = r.read(i64) catch return -1, .y = r.read(i64) catch return -1, .width = r.read(i64) catch return -1, .height = r.read(i64) catch return -1 };
    }
    r.finish() catch return -1;
    var state = s.clipboard.State.init(a, 32, true);
    defer state.deinit();
    (state.connected() catch return -1).deinit();
    if (explicit != 0) {
        var peer: p.Capabilities = .{ .count = 1 };
        peer.words[0] = caps;
        (state.receive(.{ .capabilities = .{ .reply = false, .values = peer } }) catch return -1).deinit();
    }
    const config = s.monitor_config.Configuration.init(entries[0..count]) catch return -1;
    const layout = config.encode(state.support()) catch return -1;
    const m = layout.message(a) catch return -1;
    defer m.deinit();
    if (m.data.bytes().len > capacity) return -1;
    @memcpy(output[0..m.data.bytes().len], m.data.bytes());
    return @intCast(m.data.bytes().len);
}
pub export fn monitor_create() *s.monitor_config.Coordinator {
    const value = a.create(s.monitor_config.Coordinator) catch @panic("allocation");
    value.* = .{};
    return value;
}
pub export fn monitor_destroy(value: *s.monitor_config.Coordinator) void {
    a.destroy(value);
}
pub export fn monitor_step(value: *s.monitor_config.Coordinator, op: u32, width: i64, output: *[3]i64) void {
    var replied: ?s.monitor_config.Request = null;
    switch (op) {
        0 => {
            _ = value.queue(s.monitor_config.Configuration.init(&.{.{ .id = 0, .width = width, .height = 480 }}) catch unreachable) catch unreachable;
        },
        1 => {
            if (value.next()) |v| {
                _ = value.didSend(v.id);
            }
        },
        2 => replied = value.reply(),
        3 => value.disconnected(),
        4 => value.discardDesired(),
        5 => value.reset(),
        else => {},
    }
    output.* = .{ if (value.desired) |v| v.configuration.monitors[0].width else -1, if (value.in_flight) |v| v.configuration.monitors[0].width else -1, if (replied) |v| v.configuration.monitors[0].width else -1 };
}
