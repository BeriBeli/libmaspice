//! Single-receiver cursor state; emitted snapshots own immutable references and
//! remain valid after invalidation, migration, or service destruction.
const std = @import("std");
const wire = @import("bytes.zig");
const cursor = @import("cursor_wire.zig");
pub const Payload = struct {
    flags: u16,
    header: cursor.Header,
    data: wire.Slice,
    pub fn clone(self: Payload) Payload {
        var result = self;
        result.data = self.data.clone();
        return result;
    }
    pub fn deinit(self: Payload) void {
        self.data.release();
    }
};
pub const Snapshot = struct {
    position: cursor.Position = .{},
    visible: bool = false,
    payload: ?Payload = null,
    trail: cursor.Trail = .{ .length = 0, .frequency = 0 },
    pub fn clone(self: Snapshot) Snapshot {
        var result = self;
        if (self.payload) |p| result.payload = p.clone();
        return result;
    }
    pub fn deinit(self: Snapshot) void {
        if (self.payload) |p| p.deinit();
    }
};
pub const Event = struct {
    kind: enum { initialized, updated, reset, cache_invalidated },
    snapshot: Snapshot,
    pub fn deinit(self: Event) void {
        self.snapshot.deinit();
    }
    pub fn weight(self: Event) usize {
        return if (self.snapshot.payload) |p| p.data.retainedBytes() else 0;
    }
};
pub const State = struct {
    allocator: std.mem.Allocator,
    cache: [256]?Payload = @splat(null),
    maximum_entries: usize = 256,
    initialized: bool = false,
    current: Snapshot = .{},
    pub fn init(a: std.mem.Allocator) State {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *State) void {
        self.clear();
        self.current.deinit();
        self.current = .{};
    }
    fn clear(self: *State) void {
        for (&self.cache) |*entry| {
            if (entry.*) |p| p.deinit();
            entry.* = null;
        }
    }
    fn index(self: *State, id: u64) ?usize {
        for (self.cache, 0..) |entry, i| {
            if (entry) |p| {
                if (p.header.unique == id) return i;
            }
        }
        return null;
    }
    fn resolve(self: *State, input: cursor.Payload) !?Payload {
        if (input.flags & 1 != 0) return null;
        const h = input.header orelse return error.MissingCursorHeader;
        if (input.flags & 4 != 0) {
            const i = self.index(h.unique) orelse return error.UnknownCursor;
            return self.cache[i].?.clone();
        }
        var slot: ?usize = null;
        if (input.flags & 2 != 0) {
            slot = self.index(h.unique);
            if (slot == null) {
                for (self.cache[0..@min(self.maximum_entries, self.cache.len)], 0..) |entry, i| {
                    if (entry == null) {
                        slot = i;
                        break;
                    }
                }
            }
            if (slot == null) return error.CursorCacheFull;
        }
        const result: Payload = .{ .flags = input.flags, .header = h, .data = try wire.Slice.copy(self.allocator, input.data) };
        if (slot) |i| {
            if (self.cache[i]) |old| old.deinit();
            self.cache[i] = result.clone();
        }
        return result;
    }
    fn shape(self: *State, value: cursor.Shape) !void {
        const resolved = try self.resolve(value.payload);
        if (self.current.payload) |old| old.deinit();
        self.current.payload = resolved;
        self.current.position = value.position;
        self.current.visible = value.visible and resolved != null;
    }
    pub fn apply(self: *State, command: cursor.Command) !Event {
        const requires_init = switch (command) {
            .set, .move, .hide, .trail => true,
            else => false,
        };
        if (requires_init and !self.initialized) return error.CursorInitRequired;
        const kind: @FieldType(Event, "kind") = switch (command) {
            .initialize => |v| blk: {
                self.clear();
                try self.shape(v.shape);
                self.current.trail = v.trail;
                self.initialized = true;
                break :blk .initialized;
            },
            .reset => blk: {
                self.clear();
                self.current.deinit();
                self.current = .{ .position = self.current.position };
                break :blk .reset;
            },
            .set => |v| blk: {
                try self.shape(v);
                break :blk .updated;
            },
            .move => |v| blk: {
                self.current.position = v;
                break :blk .updated;
            },
            .hide => blk: {
                self.current.visible = false;
                break :blk .updated;
            },
            .trail => |v| blk: {
                self.current.trail = v;
                break :blk .updated;
            },
            .invalidate_one => |id| blk: {
                if (self.index(id)) |i| {
                    self.cache[i].?.deinit();
                    self.cache[i] = null;
                }
                break :blk .cache_invalidated;
            },
            .invalidate_all => blk: {
                self.clear();
                break :blk .cache_invalidated;
            },
        };
        return .{ .kind = kind, .snapshot = self.current.clone() };
    }
};
