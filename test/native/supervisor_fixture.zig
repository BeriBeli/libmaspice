//! Test-only child service: independent peers drive real native supervision and
//! observe handler count continuity. This is not a production Display handler.
const std = @import("std");
const s = @import("spice");
const a = std.heap.c_allocator;
const Child = struct {
    pub const Event = struct {
        data: s.bytes.Slice,
        count: u64,
        pub fn deinit(self: Event) void {
            self.data.release();
        }
        pub fn weight(self: Event) usize {
            return self.data.bytes().len;
        }
    };
    pub const World = struct {
        allocator: std.mem.Allocator,
        pub fn create(allocator: std.mem.Allocator, _: *s.clock.Clock) !*World {
            const self = try allocator.create(World);
            self.* = .{ .allocator = allocator };
            return self;
        }
        pub fn destroy(self: *World) void {
            self.allocator.destroy(self);
        }
    };
    pub const State = struct {
        allocator: std.mem.Allocator,
        count: u64 = 0,
        pub fn create(allocator: std.mem.Allocator, _: *World, _: s.barrier.Key) !*State {
            const self = try allocator.create(State);
            self.* = .{ .allocator = allocator };
            return self;
        }
        pub fn destroy(self: *State) void {
            self.allocator.destroy(self);
        }
        pub fn step(self: *State, connection: *s.channel.Channel, token: *s.cancel.Token) !union(enum) { processed, event: Event, migration: ?s.bytes.Slice } {
            try token.check();
            const event = try connection.receive();
            switch (event) {
                .migration => |data| return .{ .migration = data },
                .message => |message| {
                    defer message.deinit();
                    try token.check();
                    self.count = try std.math.add(u64, self.count, 1);
                    const data = message.body.clone();
                    errdefer data.release();
                    try connection.complete();
                    return .{ .event = .{ .data = data, .count = self.count } };
                },
            }
        }
    };
};
const Runtime = s.supervisor.Supervisor(Child);
const Header = extern struct { kind: u32, detail: u32, generation: u64, key: u16, value: u64 };
pub export fn supervisor_fixture_create(capacity: usize) ?*Runtime {
    return Runtime.create(a, .{ .maximum_channels = 16, .event_capacity = capacity }) catch null;
}
pub export fn supervisor_fixture_connect(self: *Runtime, host: [*:0]const u8, port: u16, password: [*]const u8, size: usize) c_int {
    self.connect(.{ .host = std.mem.span(host), .port = port, .timeout_ms = 2000 }, password[0..size]) catch return -1;
    return 0;
}
pub export fn supervisor_fixture_cancel(self: *Runtime) void {
    self.cancel();
}
pub export fn supervisor_fixture_destroy(self: *Runtime) void {
    self.destroy();
}
pub export fn supervisor_fixture_next(self: *Runtime, output: *Header, data: *?[*]const u8, size: *usize) ?*Runtime.Event {
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
            output.value = event.count;
            data.* = event.data.bytes().ptr;
            size.* = event.data.bytes().len;
        },
        .migration => |event| {
            output.kind = 6;
            output.detail = @backingInt(event.kind);
            output.value = event.offer.id;
        },
    }
    return result;
}
pub export fn supervisor_fixture_event_destroy(self: ?*Runtime.Event) void {
    if (self) |event| {
        event.deinit();
        a.destroy(event);
    }
}
pub export fn supervisor_fixture_send(self: *Runtime, kind: u8, id: u8, message: u16, bytes: [*]const u8, size: usize) c_int {
    self.send(.{ .kind = kind, .id = id }, message, bytes[0..size]) catch return -1;
    return 0;
}
pub export fn supervisor_fixture_send_agent(self: *Runtime, data: [*]const u8, size: usize) c_int {
    var token: s.agent.SendToken = .{};
    const sent = self.sendAgent(1, 4, 0, data[0..size], &token) catch return -1;
    return @intFromBool(sent);
}
