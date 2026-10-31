//! Single control-worker state machine. Asynchronous completions are fenced by
//! offer ID; retained offers keep destination storage alive across cancellation.
const std = @import("std");
const migration = @import("migration.zig");
pub const Mode = union(enum) { semi_seamless, seamless: u32, switch_host };
pub const Phase = enum { idle, preparing, ready, committing, switching };
pub const Offer = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    id: u64,
    mode: Mode,
    destination: migration.Destination,
    fn create(allocator: std.mem.Allocator, id: u64, mode: Mode, destination: migration.Destination) !*Offer {
        const self = try allocator.create(Offer);
        errdefer allocator.destroy(self);
        const host = try allocator.dupe(u8, destination.host);
        errdefer allocator.free(host);
        const subject = if (destination.subject) |s| try allocator.dupe(u8, s) else null;
        self.* = .{ .allocator = allocator, .id = id, .mode = mode, .destination = .{ .host = host, .subject = subject, .port = destination.port, .secure_port = destination.secure_port } };
        return self;
    }
    pub fn retain(self: *Offer) *Offer {
        const previous = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0 and previous < std.math.maxInt(usize));
        return self;
    }
    pub fn release(self: *Offer) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            self.allocator.free(self.destination.host);
            if (self.destination.subject) |s| self.allocator.free(s);
            self.allocator.destroy(self);
        }
    }
};
pub const EventKind = enum { preparing, ready, cancelled, committing, switching, completed, failed };
pub const Action = union(enum) {
    prepare: *Offer,
    cancel: *Offer,
    commit: *Offer,
    switch_host: *Offer,
    send: migration.Reply,
    event: struct { offer: *Offer, kind: EventKind, seamless: bool = false, failure: ?anyerror = null },
    violation: anyerror,
    fn deinit(self: Action) void {
        switch (self) {
            .prepare, .cancel, .commit, .switch_host => |offer| offer.release(),
            .event => |event| event.offer.release(),
            else => {},
        }
    }
};
pub const Actions = struct {
    storage: [4]Action = undefined,
    len: usize = 0,
    fn append(self: *Actions, action: Action) void {
        std.debug.assert(self.len < self.storage.len);
        self.storage[self.len] = action;
        self.len += 1;
    }
    pub fn items(self: *const Actions) []const Action {
        return self.storage[0..self.len];
    }
    pub fn deinit(self: Actions) void {
        for (self.storage[0..self.len]) |action| action.deinit();
    }
};
pub const Coordinator = struct {
    allocator: std.mem.Allocator,
    phase: Phase = .idle,
    offer: ?*Offer = null,
    seamless: bool = false,
    next_id: u64 = 1,
    pub fn deinit(self: *Coordinator) void {
        if (self.offer) |offer| offer.release();
        self.offer = null;
        self.phase = .idle;
    }
    fn reset(self: *Coordinator) void {
        self.deinit();
        self.seamless = false;
    }
    fn event(out: *Actions, offer: *Offer, kind: EventKind, seamless: bool, failure: ?anyerror) void {
        out.append(.{ .event = .{ .offer = offer.retain(), .kind = kind, .seamless = seamless, .failure = failure } });
    }
    fn cancelCurrent(self: *Coordinator, out: *Actions, emit: bool) void {
        if (self.offer) |offer| {
            if (emit) event(out, offer, .cancelled, false, null);
            out.append(.{ .cancel = offer.retain() });
            self.reset();
        }
    }
    fn start(self: *Coordinator, destination: migration.Destination, mode: Mode) !Actions {
        const following = try std.math.add(u64, self.next_id, 1);
        const offer = try Offer.create(self.allocator, self.next_id, mode, destination);
        var out: Actions = .{};
        self.cancelCurrent(&out, true);
        self.next_id = following;
        self.offer = offer;
        if (mode == .switch_host) {
            self.phase = .switching;
            event(&out, offer, .switching, false, null);
            out.append(.{ .switch_host = offer.retain() });
        } else {
            self.phase = .preparing;
            event(&out, offer, .preparing, false, null);
            out.append(.{ .prepare = offer.retain() });
        }
        return out;
    }
    pub fn receive(self: *Coordinator, command: migration.Command) !Actions {
        var out: Actions = .{};
        switch (command) {
            .begin => |target| return self.start(target, .semi_seamless),
            .begin_seamless => |value| return self.start(value.destination, .{ .seamless = value.source_version }),
            .switch_host => |target| return self.start(target, .switch_host),
            .cancel => self.cancelCurrent(&out, true),
            .end => {
                if (self.phase != .ready or self.seamless) {
                    out.append(.{ .violation = error.UnexpectedMigrationEnd });
                    return out;
                }
                self.phase = .committing;
                event(&out, self.offer.?, .committing, false, null);
                out.append(.{ .commit = self.offer.?.retain() });
            },
            .accepted, .rejected => out.append(.{ .violation = error.UnexpectedMigrationReply }),
        }
        return out;
    }
    pub fn prepared(self: *Coordinator, id: u64, accepted: bool) Actions {
        var out: Actions = .{};
        if (self.phase != .preparing or self.offer.?.id != id) return out;
        self.seamless = self.offer.?.mode == .seamless and accepted;
        self.phase = .ready;
        event(&out, self.offer.?, .ready, self.seamless, null);
        out.append(.{ .send = if (self.seamless) .connected_seamless else .connected });
        return out;
    }
    pub fn preparationFailed(self: *Coordinator, id: u64, failure: anyerror) Actions {
        var out: Actions = .{};
        if (self.phase != .preparing or self.offer.?.id != id) return out;
        event(&out, self.offer.?, .failed, false, failure);
        out.append(.{ .send = .connect_error });
        self.reset();
        return out;
    }
    pub fn seamlessCommit(self: *Coordinator, id: u64) Actions {
        var out: Actions = .{};
        if (self.phase != .ready or !self.seamless or self.offer.?.id != id) return out;
        self.phase = .committing;
        event(&out, self.offer.?, .committing, true, null);
        return out;
    }
    pub fn finished(self: *Coordinator, id: u64, failure: ?anyerror) Actions {
        var out: Actions = .{};
        if ((self.phase != .committing and self.phase != .switching) or self.offer.?.id != id) return out;
        event(&out, self.offer.?, if (failure == null) .completed else .failed, self.seamless, failure);
        self.reset();
        return out;
    }
    pub fn disconnect(self: *Coordinator) Actions {
        var out: Actions = .{};
        self.cancelCurrent(&out, false);
        return out;
    }
};
