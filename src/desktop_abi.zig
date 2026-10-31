//! Consumer boundary for the real desktop supervisor. No protocol/state policy
//! lives here. Events and extracted frames own immutable lifetime independently.
const std = @import("std");
const s = @import("root.zig");
const a = std.heap.c_allocator;
// Embedded library threads must preserve their host's alternate signal stack.
// std.Thread's default replaces an ASan-owned mapping with Zig TLS storage,
// which ASan later tries to unmap at thread exit. This changes diagnostics
// ownership only; ReleaseSafe checks and host sanitizer instrumentation stay on.
pub const std_options: std.Options = .{ .signal_stack_size = null };
pub const Desktop = s.supervisor.Supervisor(s.desktop_child);
pub const Event = Desktop.Event;
pub const Frame = struct {
    refs: std.atomic.Value(usize) = .init(1),
    publication: s.surface.Publication,
    damage_override: ?s.damage.Journal = null,
    fn damage(self: *const Frame) s.damage.Journal {
        return self.damage_override orelse self.publication.damage();
    }
};
pub const Metadata = extern struct { generation: u64, kind: u32, detail: u32, channel_type: u8, channel_id: u8, reserved: u16, values: [40]u32, wide: [4]u64 };
pub const FrameInfo = extern struct { surface_id: u32, width: u32, height: u32, format: u32, lifecycle: u64, revision: u64, native: u32, damage_count: u32, advanced_video: u32, reserved: u32 };
pub const Rect = extern struct { x: i32, y: i32, width: u32, height: u32 };
pub const Monitor = extern struct { id: u32, surface: u32, width: u32, height: u32, x: u32, y: u32, flags: u32 };
pub const Certificate = extern struct { data: ?[*]const u8, size: usize };
fn status(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => -2,
        error.Cancelled => -31,
        error.Timeout => -30,
        error.TLSFailure => -32,
        error.ConnectionFailed => -33,
        error.ConnectionClosed => -34,
        error.AuthenticationRejected => -37,
        error.LinkRejected => -38,
        error.UnsupportedAuthentication => -39,
        error.MetalUnavailable => -50,
        else => -1,
    };
}
fn slice(data: ?[*]const u8, size: usize, maximum: usize) ![]const u8 {
    if (size > maximum or (data == null and size != 0)) return error.InvalidArgument;
    return if (data) |p| p[0..size] else &.{};
}
pub export fn spice_zig_desktop_create(metallib: ?[*:0]const u8, video: u8, output: ?*?*Desktop) c_int {
    const out = output orelse return -1;
    out.* = null;
    if (video > 2) return -1;
    const context = if (metallib) |path| s.graphics.Context.init(path) catch |err| return status(err) else null;
    defer if (context) |v| v.deinit();
    out.* = Desktop.createConfigured(a, .{ .video = @fromBackingInt(@intCast(video)) }, .{ .native = context }) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_desktop_connect(handle: ?*Desktop, host: ?[*:0]const u8, port: u16, tls_kind: u8, server_name: ?[*:0]const u8, subject: ?[*:0]const u8, certificates: ?[*]const Certificate, count: usize, timeout_ms: u32, secret: ?[*]const u8, secret_size: usize) c_int {
    const self = handle orelse return -1;
    const hostname = host orelse return -1;
    if (tls_kind > 4 or count > 4096 or (count != 0 and certificates == null)) return -1;
    const password = slice(secret, secret_size, 60) catch return -1;
    const inputs = a.alloc([]const u8, count) catch return -2;
    defer a.free(inputs);
    var total: usize = 0;
    for (inputs, 0..) |*input, i| {
        const cert = certificates.?[i];
        input.* = slice(cert.data, cert.size, 16 * 1024 * 1024 - total) catch return -1;
        total += cert.size;
    }
    self.connect(.{ .host = std.mem.span(hostname), .port = port, .timeout_ms = timeout_ms, .tls = .{ .kind = @fromBackingInt(@intCast(tls_kind)), .server_name = if (server_name) |name| std.mem.span(name) else null, .expected_subject = if (subject) |text| std.mem.span(text) else "", .certificates = inputs } }, password) catch |err| return status(err);
    return 0;
}
pub const DesktopInfo = extern struct { generation: u64, session_id: u32, multimedia_time: u32, supported_mouse_modes: u32, current_mouse_mode: u32, agent_connected: u32, channel_count: u32, agent_epoch: u64, lifecycle: u64 };
pub export fn spice_zig_desktop_info(handle: ?*Desktop, output: ?*DesktopInfo) c_int {
    const out = output orelse return -1;
    out.* = std.mem.zeroes(DesktopInfo);
    const self = handle orelse return -1;
    self.mutex.lock();
    defer self.mutex.unlock();
    const group = self.active orelse return -1;
    const boot = group.bootstrap orelse return -1;
    out.* = .{ .generation = self.generation, .session_id = boot.session_id, .multimedia_time = boot.multimedia_time, .supported_mouse_modes = boot.mouse.supported, .current_mouse_mode = boot.mouse.current, .agent_connected = @intFromBool(boot.agent_connected), .channel_count = @intCast(group.children.len), .agent_epoch = boot.agent_epoch, .lifecycle = self.lifecycle };
    return 0;
}
pub export fn spice_zig_desktop_channel(handle: ?*Desktop, generation: u64, index: usize, kind: ?*u8, id: ?*u8) c_int {
    const out_kind = kind orelse return -1;
    out_kind.* = 0;
    const out_id = id orelse return -1;
    out_id.* = 0;
    const self = handle orelse return -1;
    self.mutex.lock();
    defer self.mutex.unlock();
    const group = self.active orelse return -1;
    if (generation != self.generation or index >= group.children.len) return -1;
    out_kind.* = group.children[index].key.kind;
    out_id.* = group.children[index].key.id;
    return 0;
}
pub export fn spice_zig_desktop_cancel(handle: ?*Desktop) void {
    if (handle) |self| self.cancel();
}
pub export fn spice_zig_desktop_join(handle: ?*Desktop) void {
    if (handle) |self| self.join();
}
pub export fn spice_zig_desktop_reset(handle: ?*Desktop, video: u8) c_int {
    const self = handle orelse return -1;
    if (video > 2) return -1;
    self.reset(@fromBackingInt(@intCast(video))) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_desktop_destroy(handle: ?*Desktop) void {
    if (handle) |self| self.destroy();
}
pub export fn spice_zig_desktop_next(handle: ?*Desktop, output: ?*?*Event) c_int {
    const out = output orelse return -1;
    out.* = null;
    const self = handle orelse return -1;
    const event = a.create(Event) catch return -2;
    event.* = self.next() orelse {
        a.destroy(event);
        return 0;
    };
    out.* = event;
    return 1;
}
pub export fn spice_zig_desktop_event_destroy(handle: ?*Event) void {
    if (handle) |self| {
        self.deinit();
        a.destroy(self);
    }
}
pub export fn spice_zig_desktop_event_error(handle: ?*const Event) ?[*:0]const u8 {
    const self = handle orelse return null;
    const failure: ?anyerror = switch (self.value) {
        .failed => |err| err,
        .migration => |v| v.failure,
        else => null,
    };
    return if (failure) |err| @errorName(err).ptr else null;
}
fn audioMetadata(event: s.audio.Event, out: *Metadata) void {
    switch (event) {
        .mode => |time| {
            out.detail = 1;
            out.values[0] = time;
        },
        .start => |v| {
            out.detail = 2;
            out.values[0] = v.configuration.channels;
            out.values[1] = 1;
            out.values[2] = v.configuration.frequency;
            out.values[3] = v.time;
            out.wide[0] = v.epoch;
        },
        .packet => |v| {
            out.detail = 3;
            out.values[0] = v.time;
        },
        .stop => out.detail = 4,
        .volume => |v| {
            out.detail = 5;
            out.values[0] = v.count;
            for (v.values[0..v.count], 0..) |value, i| out.values[i + 1] = value;
        },
        .mute => |v| {
            out.detail = 6;
            out.values[0] = @intFromBool(v);
        },
        .latency => |v| {
            out.detail = 7;
            out.values[0] = v;
        },
    }
}
pub export fn spice_zig_desktop_event_metadata(handle: ?*const Event, output: ?*Metadata) c_int {
    const out = output orelse return -1;
    out.* = std.mem.zeroes(Metadata);
    const self = handle orelse return -1;
    out.generation = self.generation;
    out.channel_type = self.key.kind;
    out.channel_id = self.key.id;
    switch (self.value) {
        .connected => out.kind = 1,
        .disconnected => out.kind = 2,
        .failed => {
            out.kind = 3;
            if (self.video_failure) |failure| {
                out.detail = if (failure.reason == .hardware_unavailable) 1 else 2;
                out.values[0] = @intFromBool(failure.codec == .h265);
                out.values[1] = @intFromBool(failure.status != null);
                out.values[2] = @bitCast(failure.status orelse 0);
            }
        },
        .main => |event| {
            out.kind = 4;
            out.wide[2] = self.lifecycle;
            switch (event) {
                .mouse => |v| {
                    out.detail = 1;
                    out.values[0] = v.supported;
                    out.values[1] = v.current;
                },
                .agent_connected => |epoch| {
                    out.detail = 2;
                    out.wide[1] = epoch;
                },
                .agent_disconnected => |v| {
                    out.detail = 3;
                    out.values[0] = v.code;
                    out.wide[1] = v.epoch;
                },
                .agent_message => |v| {
                    out.detail = 4;
                    out.values[0] = v.protocol;
                    out.values[1] = v.kind;
                    out.wide[0] = v.opaque_id;
                    out.wide[1] = v.epoch;
                },
                .migration => out.detail = 5,
            }
        },
        .migration => |v| {
            out.kind = 6;
            out.detail = @backingInt(v.kind) + 1;
            out.wide[0] = v.offer.id;
            out.values[0] = @intFromBool(v.seamless);
            out.values[1] = v.offer.destination.port;
            out.values[2] = v.offer.destination.secure_port;
            out.values[3] = switch (v.offer.mode) {
                .semi_seamless => 0,
                .seamless => 1,
                .switch_host => 2,
            };
            out.values[4] = if (v.offer.mode == .seamless) v.offer.mode.seamless else 0;
            out.values[5] = @intFromBool(v.offer.destination.subject != null);
        },
        .child => |event| switch (event) {
            .display => |display| switch (display) {
                .drawing => |draw| {
                    out.kind = 5;
                    switch (draw) {
                        .created => |id| {
                            out.detail = 1;
                            out.values[0] = id;
                        },
                        .destroyed => |id| {
                            out.detail = 2;
                            out.values[0] = id;
                        },
                        .frame => |r| {
                            out.detail = 3;
                            out.values[0] = r.id;
                            out.wide[0] = r.lifecycle;
                            out.wide[1] = r.value;
                        },
                        .ignored => |id| {
                            out.detail = 5;
                            out.values[0] = id;
                        },
                    }
                },
                .monitors => |v| {
                    out.kind = 5;
                    out.detail = 4;
                    out.values[0] = v.maximum;
                    out.values[1] = @intCast(v.heads.len);
                },
                .publication => |v| {
                    out.kind = 14;
                    const r = v.frame.snapshot().revision;
                    out.values[0] = r.id;
                    out.values[1] = @intFromBool(v.frame.damage().isFull());
                    out.wide[0] = r.lifecycle;
                    out.wide[1] = r.value;
                    if (v.timing) |timing| {
                        out.values[2] = 1;
                        out.wide[2] = timing.received_ns;
                        out.wide[3] = timing.ready_ns;
                    }
                },
            },
            .inputs => |v| {
                out.kind = 7;
                switch (v) {
                    .initialized => |mods| {
                        out.detail = 1;
                        out.values[0] = mods;
                    },
                    .modifiers => |mods| {
                        out.detail = 2;
                        out.values[0] = mods;
                    },
                    .motion_ack => out.detail = 3,
                }
            },
            .cursor => |v| {
                out.kind = 8;
                out.detail = @backingInt(v.kind) + 1;
                const cursor = v.snapshot;
                out.values[0] = @bitCast(@as(i32, cursor.position.x));
                out.values[1] = @bitCast(@as(i32, cursor.position.y));
                out.values[2] = @intFromBool(cursor.visible);
                out.values[3] = cursor.trail.length;
                out.values[4] = cursor.trail.frequency;
                if (cursor.payload) |p| {
                    out.values[5] = 1;
                    out.values[6] = p.header.kind;
                    out.values[7] = p.header.width;
                    out.values[8] = p.header.height;
                    out.values[9] = p.header.hot_x;
                    out.values[10] = p.header.hot_y;
                    out.values[11] = p.flags;
                    out.wide[0] = p.header.unique;
                }
            },
            .playback => |v| {
                out.kind = 9;
                audioMetadata(v, out);
            },
            .record => |v| {
                out.kind = 10;
                audioMetadata(v, out);
            },
            .smartcard => |v| {
                out.kind = 11;
                switch (v) {
                    .initialized => |x| {
                        out.detail = 1;
                        out.values[0] = x.version;
                    },
                    .completed => |x| {
                        out.detail = 2;
                        out.values[0] = @backingInt(x.request);
                        out.values[1] = x.reader;
                        out.values[2] = x.code;
                    },
                    .apdu => |x| {
                        out.detail = 3;
                        out.values[0] = x.reader;
                    },
                    .flush => |reader| {
                        out.detail = 4;
                        out.values[0] = reader;
                    },
                }
            },
            .usb => out.kind = 12,
            .webdav => |v| {
                out.kind = 13;
                switch (v) {
                    .initialized => |x| {
                        out.detail = 1;
                        out.values[0] = @intFromBool(x.opened);
                    },
                    .port => |x| {
                        out.detail = 2;
                        out.values[0] = @backingInt(x);
                    },
                    .request => |x| {
                        out.detail = 3;
                        out.wide[0] = @bitCast(x.client);
                    },
                    .closed => |x| {
                        out.detail = 4;
                        out.wide[0] = @bitCast(x);
                    },
                }
            },
        },
    }
    return 0;
}
pub export fn spice_zig_desktop_event_data(handle: ?*const Event, count: ?*usize) ?[*]const u8 {
    const size = count orelse return null;
    size.* = 0;
    const self = handle orelse return null;
    const bytes: []const u8 = switch (self.value) {
        .main => |v| switch (v) {
            .agent_message => |m| m.data.bytes(),
            .migration => |m| m.storage.bytes(),
            else => &.{},
        },
        .migration => |v| v.offer.destination.host,
        .child => |v| switch (v) {
            .cursor => |x| if (x.snapshot.payload) |p| p.data.bytes() else &.{},
            .playback, .record => |x| if (x == .packet) x.packet.data.bytes() else &.{},
            .smartcard => |x| switch (x) {
                .initialized => |y| y.capabilities.bytes(),
                .apdu => |y| y.data.bytes(),
                else => &.{},
            },
            .usb => |x| x.bytes(),
            .webdav => |x| switch (x) {
                .initialized => |y| y.name.bytes(),
                .request => |y| y.data.bytes(),
                else => &.{},
            },
            else => &.{},
        },
        else => &.{},
    };
    size.* = bytes.len;
    return if (bytes.len == 0) null else bytes.ptr;
}
pub export fn spice_zig_desktop_event_migration_subject(handle: ?*const Event, count: ?*usize) ?[*]const u8 {
    const size = count orelse return null;
    size.* = 0;
    const self = handle orelse return null;
    if (self.value != .migration) return null;
    const subject = self.value.migration.offer.destination.subject orelse return null;
    size.* = subject.len;
    return subject.ptr;
}
pub export fn spice_zig_desktop_event_monitor(handle: ?*const Event, index: usize, output: ?*Monitor) c_int {
    const out = output orelse return -1;
    out.* = std.mem.zeroes(Monitor);
    const self = handle orelse return -1;
    if (self.value != .child or self.value.child != .display or self.value.child.display != .monitors) return -1;
    const heads = self.value.child.display.monitors.heads;
    if (index >= heads.len) return -1;
    const h = heads[index];
    out.* = .{ .id = h.id, .surface = h.surface, .width = h.width, .height = h.height, .x = h.x, .y = h.y, .flags = h.flags };
    return 0;
}
pub export fn spice_zig_desktop_event_frame(handle: ?*const Event, output: ?*?*Frame) c_int {
    const out = output orelse return -1;
    out.* = null;
    const self = handle orelse return -1;
    if (self.value != .child or self.value.child != .display or self.value.child.display != .publication) return -1;
    const frame = a.create(Frame) catch return -2;
    frame.* = .{ .publication = self.value.child.display.publication.frame.retain() };
    out.* = frame;
    return 0;
}
pub export fn spice_zig_frame_retain(handle: ?*Frame) ?*Frame {
    const self = handle orelse return null;
    const old = self.refs.fetchAdd(1, .monotonic);
    std.debug.assert(old > 0 and old < std.math.maxInt(usize));
    return self;
}
pub export fn spice_zig_frame_release(handle: ?*Frame) void {
    if (handle) |self| if (self.refs.fetchSub(1, .acq_rel) == 1) {
        self.publication.release();
        a.destroy(self);
    };
}
pub export fn spice_zig_frame_info(handle: ?*const Frame, output: ?*FrameInfo) c_int {
    const out = output orelse return -1;
    out.* = std.mem.zeroes(FrameInfo);
    const self = handle orelse return -1;
    const snapshot = self.publication.snapshot();
    out.* = .{ .surface_id = snapshot.revision.id, .width = @intCast(snapshot.width), .height = @intCast(snapshot.height), .format = @backingInt(snapshot.format), .lifecycle = snapshot.revision.lifecycle, .revision = snapshot.revision.value, .native = @intFromBool(snapshot.backing == .native), .damage_count = @intCast(if (self.damage().full) @as(usize, 1) else self.damage().count), .advanced_video = @intFromBool(snapshot.advanced_video), .reserved = 0 };
    return 0;
}
pub export fn spice_zig_frame_damage(handle: ?*const Frame, index: usize, output: ?*Rect) c_int {
    const out = output orelse return -1;
    out.* = std.mem.zeroes(Rect);
    const self = handle orelse return -1;
    const journal = self.damage();
    if (index >= (if (journal.full) @as(usize, 1) else journal.count)) return -1;
    const r: s.surface.Rect = if (journal.full) .{ .x = 0, .y = 0, .width = @intCast(journal.width), .height = @intCast(journal.height) } else journal.rectangles[index];
    out.* = .{ .x = @intCast(r.x), .y = @intCast(r.y), .width = @intCast(r.width), .height = @intCast(r.height) };
    return 0;
}
pub export fn spice_zig_frame_pixels(handle: ?*Frame, data: ?*?[*]const u8, count: ?*usize) c_int {
    const out = data orelse return -1;
    out.* = null;
    const size = count orelse return -1;
    size.* = 0;
    const self = handle orelse return -1;
    const bytes = self.publication.pixels() catch |err| return status(err);
    out.* = bytes.ptr;
    size.* = bytes.len;
    return 0;
}
pub export fn spice_zig_frame_copy_pixels(handle: ?*Frame, destination: ?[*]u8, size: usize) c_int {
    const self = handle orelse return -1;
    const bytes = destination orelse return -1;
    const snapshot = self.publication.snapshot();
    const expected = std.math.mul(usize, std.math.mul(usize, snapshot.width, 4) catch return -1, snapshot.height) catch return -1;
    if (size != expected) return -1;
    self.publication.copyPixels(bytes[0..size]) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_frame_texture(handle: ?*const Frame) ?*anyopaque {
    const self = handle orelse return null;
    return switch (self.publication.snapshot().backing) {
        .native => |frame| frame.texture(),
        else => null,
    };
}
pub export fn spice_zig_frame_iosurface(handle: ?*const Frame) ?*anyopaque {
    const self = handle orelse return null;
    return switch (self.publication.snapshot().backing) {
        .native => |frame| frame.surface(),
        else => null,
    };
}
pub export fn spice_zig_desktop_set_demand(handle: ?*Desktop, channel: u8, id: u32, demand: u8) c_int {
    const self = handle orelse return -1;
    if (demand > 1) return -1;
    self.setFrameDemand(channel, id, demand == 1) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_desktop_acknowledge_frame(handle: ?*Desktop, channel: u8, id: u32, lifecycle: u64, revision: u64) c_int {
    const self = handle orelse return -1;
    self.acknowledgeFrame(channel, .{ .id = id, .lifecycle = lifecycle, .value = revision }) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_desktop_send(handle: ?*Desktop, kind: u8, id: u8, message: u16, data: ?[*]const u8, size: usize) c_int {
    const self = handle orelse return -1;
    const bytes = slice(data, size, 64 * 1024 * 1024) catch return -1;
    self.send(.{ .kind = kind, .id = id }, message, bytes) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_desktop_input(handle: ?*Desktop, channel: u8, kind: u8, x: i32, y: i32, display: u8) c_int {
    const self = handle orelse return -1;
    const input: s.inputs.Input = switch (kind) {
        0 => .{ .key_down = @bitCast(x) },
        1 => .{ .key_up = @bitCast(x) },
        2 => .{ .lock_modifiers = std.math.cast(u16, x) orelse return -1 },
        3 => .{ .motion = .{ .dx = x, .dy = y } },
        4 => .{ .position = .{ .x = @bitCast(x), .y = @bitCast(y), .display_id = display } },
        5, 6 => blk: {
            const button = std.enums.fromInt(s.inputs.Button, x) orelse return -1;
            break :blk if (kind == 5) .{ .press = button } else .{ .release = button };
        },
        else => return -1,
    };
    self.sendInput(channel, input) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_desktop_record(handle: ?*Desktop, channel: u8, begin: u8, time: u32, data: ?[*]const u8, size: usize) c_int {
    const self = handle orelse return -1;
    if (begin > 1 or (begin == 1 and size != 0)) return -1;
    const bytes = slice(data, size, s.audio_wire.maximum_packet) catch return -1;
    self.sendRecord(channel, if (begin == 1) .{ .begin = time } else .{ .packet = .{ .time = time, .bytes = bytes } }) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_desktop_playback_delay(handle: ?*Desktop, channel: u8, delay: u32) c_int {
    const self = handle orelse return -1;
    self.reportPlaybackDelay(channel, delay) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_desktop_smartcard(handle: ?*Desktop, channel: u8, kind: u32, reader: u32, data: ?[*]const u8, size: usize) c_int {
    const self = handle orelse return -1;
    const bytes = slice(data, size, 64 * 1024 + 16) catch return -1;
    const tag = std.enums.fromInt(s.smartcard_wire.Kind, kind) orelse return -1;
    self.sendSmartcard(channel, .{ .kind = tag, .reader = reader, .bytes = bytes }) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_desktop_usb(handle: ?*Desktop, channel: u8, data: ?[*]const u8, size: usize) c_int {
    const self = handle orelse return -1;
    const bytes = slice(data, size, 1024 * 1024) catch return -1;
    self.sendUSB(channel, bytes) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_desktop_webdav(handle: ?*Desktop, channel: u8, client: i64, data: ?[*]const u8, size: usize) c_int {
    const self = handle orelse return -1;
    const bytes = slice(data, size, 65535) catch return -1;
    self.sendWebDAV(channel, client, bytes) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_desktop_agent(handle: ?*Desktop, protocol: u32, kind: u32, opaque_id: u64, data: ?[*]const u8, size: usize, token: ?*s.cancel.Token) c_int {
    const self = handle orelse return -1;
    const cancellation = token orelse return -1;
    const bytes = slice(data, size, 16 * 1024 * 1024) catch return -1;
    return @intFromBool(self.sendAgentCancellable(protocol, kind, opaque_id, bytes, cancellation) catch |err| return status(err));
}

/// Epochs come from the originating event or the initial bootstrap snapshot.
pub export fn spice_zig_desktop_agent_at(handle: ?*Desktop, session_epoch: u64, agent_epoch: u64, protocol: u32, kind: u32, opaque_id: u64, data: ?[*]const u8, size: usize, token: ?*s.cancel.Token) c_int {
    const self = handle orelse return -1;
    const cancellation = token orelse return -1;
    const bytes = slice(data, size, 16 * 1024 * 1024) catch return -1;
    const sent = self.sendAgentAt(.{ .session = session_epoch, .agent = agent_epoch }, protocol, kind, opaque_id, bytes, cancellation) catch |err| return if (err == error.StaleAgentGeneration) -45 else status(err);
    return if (sent) 1 else 0;
}
pub export fn spice_zig_desktop_send_token_create() ?*s.cancel.Token {
    const token = a.create(s.cancel.Token) catch return null;
    token.* = .{};
    return token;
}
pub export fn spice_zig_desktop_send_token_cancel(handle: ?*s.cancel.Token) void {
    if (handle) |token| token.cancel();
}
pub export fn spice_zig_desktop_send_token_destroy(handle: ?*s.cancel.Token) void {
    if (handle) |token| {
        token.deinit();
        a.destroy(token);
    }
}

pub const PresentationCompletion = extern struct { surface_id: u32, reserved: u32, lifecycle: u64, revision: u64, epoch: u64, succeeded: u32, current: u32 };
const PresentationCallback = *const fn (?*anyopaque, *const PresentationCompletion) callconv(.c) void;
pub const Presentation = struct {
    core: *s.presenter.Presenter,
    callback: PresentationCallback,
    user: ?*anyopaque,
    fn complete(p: *anyopaque, result: s.presenter.Completion) void {
        const self: *Presentation = @ptrCast(@alignCast(p));
        const value: PresentationCompletion = .{ .surface_id = result.revision.id, .reserved = 0, .lifecycle = result.revision.lifecycle, .revision = result.revision.value, .epoch = result.epoch, .succeeded = @intFromBool(result.succeeded), .current = @intFromBool(result.current) };
        self.callback(self.user, &value);
    }
};
pub export fn spice_zig_desktop_presenter_create(handle: ?*Desktop, path: ?[*:0]const u8, callback: ?PresentationCallback, user: ?*anyopaque, output: ?*?*Presentation) c_int {
    const out = output orelse return -1;
    out.* = null;
    const desktop = handle orelse return -1;
    const library = path orelse return -1;
    const cb = callback orelse return -1;
    const native = desktop.child_configuration.native orelse return -50;
    const self = a.create(Presentation) catch return -2;
    const core = s.presenter.Presenter.create(a, native, library, .{ .context = self, .completed = Presentation.complete }) catch |err| {
        a.destroy(self);
        return status(err);
    };
    self.* = .{ .core = core, .callback = cb, .user = user };
    out.* = self;
    return 0;
}
pub export fn spice_zig_desktop_presenter_destroy(handle: ?*Presentation) void {
    if (handle) |self| {
        self.core.destroy();
        a.destroy(self);
    }
}
pub export fn spice_zig_desktop_presenter_reset(handle: ?*Presentation, visible: u8) c_int {
    const self = handle orelse return -1;
    if (visible > 1) return -1;
    self.core.reset(visible == 1) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_desktop_presenter_submit(handle: ?*Presentation, frame: ?*const Frame, texture: ?*anyopaque, width: u32, height: u32, drawable: ?*anyopaque) c_int {
    const self = handle orelse return -1;
    const input = frame orelse return -1;
    const target = texture orelse return -1;
    const result = self.core.submit(input.publication, .{ .texture = target, .width = width, .height = height, .drawable = drawable }) catch |err| return status(err);
    return @intCast(@backingInt(result));
}
pub export fn spice_zig_desktop_presenter_submit_observed(handle: ?*Presentation, frame: ?*const Frame, texture: ?*anyopaque, width: u32, height: u32, drawable: ?*anyopaque, observer: ?*const s.presenter.Observer, commit_ns: ?*u64) c_int {
    if (commit_ns) |ns| ns.* = 0;
    const self = handle orelse return -1;
    const input = frame orelse return -1;
    const target = texture orelse return -1;
    const result = self.core.submit(input.publication, .{ .texture = target, .width = width, .height = height, .drawable = drawable, .observer = observer, .commit_ns = commit_ns }) catch |err| return status(err);
    return @intCast(@backingInt(result));
}
pub export fn spice_zig_desktop_presenter_wait_idle(handle: ?*Presentation) void {
    if (handle) |self| self.core.waitIdle();
}

comptime {
    _ = @import("agent_abi.zig");
    _ = @import("agent_runner_abi.zig");
    _ = @import("agent_route_abi.zig");
    _ = @import("audio_abi.zig");
    _ = @import("audio_route_abi.zig");
    _ = @import("webdav_abi.zig");
    _ = @import("webdav_route_abi.zig");
    _ = @import("usb_abi.zig");
    _ = @import("usb_route_abi.zig");
    _ = @import("desktop_source_abi.zig");
    _ = @import("diagnostics_abi.zig");
    _ = @import("pipeline_abi.zig");
}
