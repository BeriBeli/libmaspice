//! Test adapter around the real Display service and supervisor.
const std = @import("std");
const s = @import("spice");
const a = std.heap.c_allocator;
const Runtime = s.supervisor.Supervisor(s.desktop_child);
const Header = extern struct { kind: u32, detail: u32, generation: u64, key: u16, value: u64 };
pub export fn display_fixture_create(capacity: usize) ?*Runtime {
    return Runtime.create(a, .{ .maximum_channels = 16, .event_capacity = capacity }) catch null;
}
pub export fn display_fixture_create_native(capacity: usize, path: [*:0]const u8) ?*Runtime {
    const context = s.graphics.Context.init(path) catch return null;
    defer context.deinit(); // Runtime owns its independent retain before connect.
    return Runtime.createConfigured(a, .{ .maximum_channels = 16, .event_capacity = capacity }, .{ .native = context }) catch null;
}
pub export fn display_fixture_native_submissions(self: *Runtime, id: u32) i64 {
    self.mutex.lock();
    defer self.mutex.unlock();
    const group = self.active orelse return -1;
    for (group.children, group.states) |connection, state| {
        if (connection.key.kind != 2 or connection.key.id != 0) continue;
        const snapshot = state.value.display.core.surfaces.snapshot(id) catch return -1;
        defer snapshot.deinit();
        if (snapshot.backing != .native) return -1;
        return @intCast((group.world.?.native orelse return -1).submitted());
    }
    return -1;
}
pub export fn display_fixture_connect(self: *Runtime, host: [*:0]const u8, port: u16, password: [*]const u8, size: usize) c_int {
    self.connect(.{ .host = std.mem.span(host), .port = port, .timeout_ms = 2000 }, password[0..size]) catch return -1;
    return 0;
}
pub export fn display_fixture_cancel(self: *Runtime) void {
    self.cancel();
}
pub export fn display_fixture_destroy(self: *Runtime) void {
    self.destroy();
}
pub export fn display_fixture_next(self: *Runtime, output: *Header, data: *?[*]const u8, size: *usize) ?*Runtime.Event {
    const value = self.next() orelse return null;
    const result = a.create(Runtime.Event) catch {
        value.deinit();
        return null;
    };
    result.* = value;
    output.* = std.mem.zeroes(Header);
    output.generation = value.generation;
    output.key = value.key.index();
    data.* = null;
    size.* = 0;
    switch (value.value) {
        .connected => output.kind = 1,
        .disconnected => output.kind = 2,
        .failed => output.kind = 3,
        .main => |event| {
            output.kind = 4;
            switch (event) {
                .mouse => |mouse| output.value = mouse.current,
                .agent_message => |message| {
                    output.value = message.kind;
                    data.* = message.data.bytes().ptr;
                    size.* = message.data.bytes().len;
                },
                else => {},
            }
        },
        .child => |event| {
            output.kind = 5;
            switch (event) {
                .display => |display| switch (display) {
                    .drawing => |draw| switch (draw) {
                        .created => |id| {
                            output.detail = 1;
                            output.value = id;
                        },
                        .destroyed => |id| {
                            output.detail = 2;
                            output.value = id;
                        },
                        .frame => |revision| {
                            output.detail = 3;
                            output.value = revision.value;
                        },
                        .ignored => {},
                    },
                    .publication => |frame| {
                        output.kind = 14;
                        output.detail = if (frame.frame.damage().isFull()) 1 else 2;
                        output.value = frame.frame.snapshot().revision.value;
                        switch (frame.frame.snapshot().backing) {
                            .cpu => |pixels| {
                                data.* = pixels.pixels().ptr;
                                size.* = pixels.pixels().len;
                            },
                            .native => output.detail |= 4,
                        }
                    },
                    .monitors => |m| {
                        output.detail = 4;
                        output.value = m.heads.len;
                    },
                },
                .inputs => |input| {
                    output.kind = 7;
                    switch (input) {
                        .initialized => |v| {
                            output.detail = 1;
                            output.value = v;
                        },
                        .modifiers => |v| {
                            output.detail = 2;
                            output.value = v;
                        },
                        .motion_ack => output.detail = 3,
                    }
                },
                .playback, .record => |v| {
                    output.kind = if (event == .playback) 9 else 10;
                    switch (v) {
                        .mode => |time| {
                            output.detail = 1;
                            output.value = time;
                        },
                        .start => |start| {
                            output.detail = 2;
                            output.value = start.configuration.frequency;
                        },
                        .packet => |packet| {
                            output.detail = 3;
                            output.value = packet.time;
                            data.* = packet.data.bytes().ptr;
                            size.* = packet.data.bytes().len;
                        },
                        .stop => output.detail = 4,
                        .volume => |volume| {
                            output.detail = 5;
                            output.value = volume.count;
                        },
                        .mute => |mute| {
                            output.detail = 6;
                            output.value = @intFromBool(mute);
                        },
                        .latency => |delay| {
                            output.detail = 7;
                            output.value = delay;
                        },
                    }
                },
                .smartcard => |v| {
                    output.kind = 11;
                    switch (v) {
                        .initialized => |init| {
                            output.detail = 1;
                            output.value = init.version;
                            data.* = init.capabilities.bytes().ptr;
                            size.* = init.capabilities.bytes().len;
                        },
                        .completed => |done| {
                            output.detail = 2;
                            output.value = @as(u64, @backingInt(done.request)) << 32 | done.code;
                        },
                        .apdu => |packet| {
                            output.detail = 3;
                            output.value = packet.reader;
                            data.* = packet.data.bytes().ptr;
                            size.* = packet.data.bytes().len;
                        },
                        .flush => |reader| {
                            output.detail = 4;
                            output.value = reader;
                        },
                    }
                },
                .usb => |payload| {
                    output.kind = 12;
                    output.value = payload.bytes().len;
                    size.* = payload.bytes().len;
                    data.* = payload.bytes().ptr;
                },
                .webdav => |v| {
                    output.kind = 13;
                    switch (v) {
                        .initialized => |init| {
                            output.detail = 1;
                            output.value = @intFromBool(init.opened);
                            data.* = init.name.bytes().ptr;
                            size.* = init.name.bytes().len;
                        },
                        .port => |port| {
                            output.detail = 2;
                            output.value = @backingInt(port);
                        },
                        .request => |request| {
                            output.detail = 3;
                            output.value = @bitCast(request.client);
                            data.* = request.data.bytes().ptr;
                            size.* = request.data.bytes().len;
                        },
                        .closed => |client| {
                            output.detail = 4;
                            output.value = @bitCast(client);
                        },
                    }
                },
                .cursor => |cursor| {
                    output.kind = 8;
                    output.detail = @as(u32, @backingInt(cursor.kind)) + 1;
                    output.value = @intFromBool(cursor.snapshot.visible);
                    if (cursor.snapshot.payload) |payload| {
                        data.* = payload.data.bytes().ptr;
                        size.* = payload.data.bytes().len;
                    }
                },
            }
        },
        .migration => |event| {
            output.kind = 6;
            output.detail = @backingInt(event.kind);
            output.value = event.offer.id;
        },
    }
    return result;
}
pub export fn display_fixture_event_destroy(self: ?*Runtime.Event) void {
    if (self) |event| {
        event.deinit();
        a.destroy(event);
    }
}
pub export fn display_fixture_send(self: *Runtime, kind: u8, id: u8, message: u16, bytes: [*]const u8, size: usize) c_int {
    self.send(.{ .kind = kind, .id = id }, message, bytes[0..size]) catch return -1;
    return 0;
}
pub export fn display_fixture_send_agent(self: *Runtime, data: [*]const u8, size: usize) c_int {
    var token: s.agent.SendToken = .{};
    const sent = self.sendAgent(1, 4, 0, data[0..size], &token) catch return -1;
    return @intFromBool(sent);
}

pub export fn display_fixture_pixels(self: *Runtime, id: u32, out: [*]u8, length: usize) c_int {
    self.mutex.lock();
    defer self.mutex.unlock();
    const group = self.active orelse return -1;
    for (group.children, group.states) |connection, state| {
        if (connection.key.kind != 2 or connection.key.id != 0) continue;
        const snapshot = state.value.display.core.surfaces.snapshot(id) catch return -1;
        defer snapshot.deinit();
        if (length != snapshot.width * snapshot.height * 4) return -1;
        const pixels = snapshot.backing.read() catch return -1;
        defer pixels.finish() catch {};
        for (0..snapshot.height) |row| @memcpy(out[row * snapshot.width * 4 ..][0 .. snapshot.width * 4], pixels.bytes[row * pixels.stride ..][0 .. snapshot.width * 4]);
        return 0;
    }
    return -1;
}

pub export fn display_fixture_input(self: *Runtime, id: u8, kind: u8, x: i32, y: i32) c_int {
    const event: s.inputs.Input = switch (kind) {
        0 => .{ .key_down = @bitCast(x) },
        1 => .{ .key_up = @bitCast(x) },
        2 => .{ .lock_modifiers = std.math.cast(u16, x) orelse return -1 },
        3 => .{ .motion = .{ .dx = x, .dy = y } },
        4 => .{ .position = .{ .x = @bitCast(x), .y = @bitCast(y), .display_id = 0 } },
        5, 6 => blk: {
            const button = std.enums.fromInt(s.inputs.Button, x) orelse return -1;
            break :blk if (kind == 5) .{ .press = button } else .{ .release = button };
        },
        else => return -1,
    };
    self.sendInput(id, event) catch return -1;
    return 0;
}
pub export fn display_fixture_cursor_wire(kind: u16, bytes: [*]const u8, size: usize) c_int {
    _ = s.cursor_wire.decode(kind, bytes[0..size]) catch return -1;
    return 0;
}

pub export fn display_fixture_audio_wire(record: bool, kind: u16, bytes: [*]const u8, size: usize) c_int {
    _ = (if (record) s.audio_wire.record(kind, bytes[0..size]) else s.audio_wire.playback(kind, bytes[0..size])) catch return -1;
    return 0;
}
pub export fn display_fixture_record(self: *Runtime, id: u8, begin: bool, time: u32, bytes: [*]const u8, size: usize) c_int {
    self.sendRecord(id, if (begin) .{ .begin = time } else .{ .packet = .{ .time = time, .bytes = bytes[0..size] } }) catch return -1;
    return 0;
}
pub export fn display_fixture_playback_delay(self: *Runtime, id: u8, delay: u32) c_int {
    self.reportPlaybackDelay(id, delay) catch return -1;
    return 0;
}
pub export fn display_fixture_clock_delay(self: *Runtime) i64 {
    self.mutex.lock();
    defer self.mutex.unlock();
    const group = self.active orelse return -2;
    return if (group.media.?.playbackDelay()) |delay| delay else -1;
}

pub export fn display_fixture_peripheral_wire(kind: u16, bytes: [*]const u8, size: usize) c_int {
    switch (kind) {
        8 => {
            _ = s.smartcard_wire.decode(bytes[0..size]) catch return -1;
        },
        9 => {
            s.vmc.validate(bytes[0..size]) catch return -1;
        },
        201 => {
            _ = s.webdav.portInit(bytes[0..size]) catch return -1;
        },
        202 => {
            _ = s.webdav.portEvent(bytes[0..size]) catch return -1;
        },
        else => return -1,
    }
    return 0;
}
pub export fn display_fixture_smartcard(self: *Runtime, id: u8, kind: u32, reader: u32, bytes: [*]const u8, size: usize) c_int {
    const message: s.smartcard_wire.Message = .{ .kind = std.enums.fromInt(s.smartcard_wire.Kind, kind) orelse return -1, .reader = reader, .bytes = bytes[0..size] };
    self.sendSmartcard(id, message) catch return -1;
    return 0;
}
pub export fn display_fixture_usb(self: *Runtime, id: u8, bytes: [*]const u8, size: usize) c_int {
    self.sendUSB(id, bytes[0..size]) catch return -1;
    return 0;
}
pub export fn display_fixture_webdav(self: *Runtime, id: u8, client: i64, bytes: [*]const u8, size: usize) c_int {
    self.sendWebDAV(id, client, bytes[0..size]) catch return -1;
    return 0;
}

pub export fn display_fixture_frame_control(self: *Runtime, channel_id: u8, surface_id: u32, operation: u8, lifecycle: u64, revision: u64) c_int {
    switch (operation) {
        0, 1 => self.setFrameDemand(channel_id, surface_id, operation == 1) catch return -1,
        2 => self.acknowledgeFrame(channel_id, .{ .id = surface_id, .lifecycle = lifecycle, .value = revision }) catch return -1,
        3 => self.flushFrames(channel_id) catch return -1,
        else => return -1,
    }
    return 0;
}
pub export fn display_fixture_frame_snapshots(self: *Runtime, channel_id: u8) i64 {
    const metrics = self.frameMetrics(channel_id) catch return -1;
    return @intCast(metrics.snapshots);
}
