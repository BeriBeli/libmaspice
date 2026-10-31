//! One serialized owner per framer. Returned messages/batches own immutable
//! slices independently of reset/destruction. All fallible parsing precedes
//! queue consumption; allocation errors and malformed batches are retryable.
const std = @import("std");
const wire = @import("bytes.zig");
pub const Mode = enum {
    full,
    mini,
    pub fn size(self: Mode) usize {
        return if (self == .full) 18 else 6;
    }
};
pub const Limits = struct {
    message: usize = 64 * 1024 * 1024,
    buffered: usize = 128 * 1024 * 1024,
    segments: usize = 4096,
};
pub const Message = struct {
    serial: ?u64,
    kind: u16,
    sub_list: ?u32,
    body: wire.Slice,
    pub fn deinit(self: Message) void {
        self.body.release();
    }
};
pub const Logical = struct {
    kind: u16,
    range: wire.Range,
    pub fn acknowledgmentCount(self: Logical, index: usize, count: usize) u1 {
        _ = self;
        return @intFromBool(index + 1 == count);
    }
};
pub const Batch = struct {
    allocator: std.mem.Allocator,
    message: Message,
    logical: []Logical,
    /// Even an empty LIST represents one physical ACK/serial unit.
    pub const acknowledgment_count = 1;
    pub fn deinit(self: Batch) void {
        self.allocator.free(self.logical);
        self.message.deinit();
    }
    pub fn body(self: Batch, index: usize) []const u8 {
        const range = self.logical[index].range;
        return self.message.body.bytes()[range.start..range.end];
    }
    pub fn parse(allocator: std.mem.Allocator, message: Message, maximum: usize) !Batch {
        if (maximum > 4096) return error.MessageTooLarge;
        const bytes = message.body.bytes();
        var logical: std.ArrayList(Logical) = .empty;
        errdefer logical.deinit(allocator);
        if (message.sub_list == null or (message.kind != 8 and message.sub_list.? == 0)) {
            try logical.append(allocator, .{ .kind = message.kind, .range = .{ .start = 0, .end = bytes.len } });
        } else {
            const offset = message.sub_list.?;
            var reader = try wire.Reader.init(bytes, offset);
            const count = try reader.read(u16);
            if (count > maximum) return error.MessageTooLarge;
            const table = try reader.take(@as(usize, count) * 4);
            const metadata_end = reader.offset;
            const ranges = try allocator.alloc(wire.Range, count);
            defer allocator.free(ranges);
            try logical.ensureTotalCapacity(allocator, @as(usize, count) + @intFromBool(message.kind != 8));
            var offsets = try wire.Reader.init(table, 0);
            for (ranges) |*range| {
                const start = try offsets.read(u32);
                if (start < metadata_end) return error.InvalidOffset;
                // Swift reports Truncated for a submessage beyond the body.
                if (start > bytes.len) return error.Truncated;
                var sub = try wire.Reader.init(bytes, start);
                const kind = try sub.read(u16);
                const length = try sub.read(u32);
                const body_start = sub.offset;
                _ = try sub.take(length);
                range.* = .{ .start = start, .end = sub.offset };
                logical.appendAssumeCapacity(.{ .kind = kind, .range = .{ .start = body_start, .end = sub.offset } });
            }
            std.mem.sort(wire.Range, ranges, {}, struct {
                fn less(_: void, a: wire.Range, b: wire.Range) bool {
                    return a.start < b.start;
                }
            }.less);
            for (ranges, 0..) |range, index| {
                if (index > 0 and ranges[index - 1].end > range.start) return error.InvalidOffset;
            }
            if (message.kind != 8) logical.appendAssumeCapacity(.{ .kind = message.kind, .range = .{ .start = 0, .end = offset } });
        }
        const items = try logical.toOwnedSlice(allocator);
        var owned = message;
        owned.body = message.body.clone();
        return .{ .allocator = allocator, .message = owned, .logical = items };
    }
};

pub const Framer = struct {
    const Segment = struct { slice: wire.Slice, next: ?*Segment = null };
    const Peek = struct { message: Message, size: usize };
    allocator: std.mem.Allocator,
    mode: Mode,
    limits: Limits = .{},
    head: ?*Segment = null,
    tail: ?*Segment = null,
    head_offset: usize = 0,
    buffered: usize = 0,
    segment_count: usize = 0,
    cached: ?Peek = null,
    coalesces: u64 = 0,
    copy_bytes: u64 = 0,

    pub fn deinit(self: *Framer) void {
        self.reset();
    }
    pub fn reset(self: *Framer) void {
        if (self.cached) |cached| cached.message.deinit();
        self.cached = null;
        while (self.head) |segment| {
            self.head = segment.next;
            segment.slice.release();
            self.allocator.destroy(segment);
        }
        self.tail = null;
        self.head_offset = 0;
        self.buffered = 0;
        self.segment_count = 0;
    }
    fn validateAppend(self: Framer, length: usize) !void {
        if (self.segment_count >= self.limits.segments) return error.TooManySegments;
        if (length > self.limits.buffered - self.buffered) return error.MessageTooLarge;
    }
    /// Copies the incoming chunk exactly once; empty chunks use no capacity.
    pub fn append(self: *Framer, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.validateAppend(bytes.len);
        const owned = try wire.Slice.copy(self.allocator, bytes);
        defer owned.release();
        try self.appendShared(owned);
    }
    /// Acquires its own reference only on success. Caller retains ownership.
    pub fn appendShared(self: *Framer, slice: wire.Slice) !void {
        if (slice.bytes().len == 0) return;
        try self.validateAppend(slice.bytes().len);
        const segment = try self.allocator.create(Segment);
        segment.* = .{ .slice = slice.clone() };
        if (self.tail) |tail| tail.next = segment else self.head = segment;
        self.tail = segment;
        self.buffered += slice.bytes().len;
        self.segment_count += 1;
    }
    fn copyAt(self: Framer, offset: usize, destination: []u8) void {
        var skip = self.head_offset + offset;
        var current = self.head;
        var copied: usize = 0;
        while (current) |segment| : (current = segment.next) {
            const bytes = segment.slice.bytes();
            if (skip >= bytes.len) {
                skip -= bytes.len;
                continue;
            }
            const count = @min(destination.len - copied, bytes.len - skip);
            @memcpy(destination[copied..][0..count], bytes[skip..][0..count]);
            copied += count;
            if (copied == destination.len) return;
            skip = 0;
        }
        std.debug.assert(copied == destination.len);
    }
    fn bodySlice(self: *Framer, offset: usize, count: usize) !wire.Slice {
        var skip = self.head_offset + offset;
        var current = self.head;
        while (current) |segment| : (current = segment.next) {
            const bytes = segment.slice.bytes();
            if (skip > bytes.len or (skip == bytes.len and count > 0)) {
                skip -= bytes.len;
                continue;
            }
            if (count <= bytes.len - skip) return segment.slice.subslice(skip, count);
            const owned = try wire.Slice.allocate(self.allocator, count);
            self.copyAt(offset, owned.storage.bytes);
            self.coalesces +|= 1;
            self.copy_bytes +|= count;
            return owned;
        }
        unreachable; // Complete header/body was checked before slicing.
    }
    fn peek(self: *Framer) !?Peek {
        if (self.cached) |cached| return cached;
        if (self.buffered < self.mode.size()) return null;
        var header: [18]u8 = undefined;
        self.copyAt(0, header[0..self.mode.size()]);
        var reader = try wire.Reader.init(header[0..self.mode.size()], 0);
        const serial = if (self.mode == .full) try reader.read(u64) else null;
        const kind = try reader.read(u16);
        const size = try reader.read(u32);
        const sub_list = if (self.mode == .full) try reader.read(u32) else null;
        if (size > self.limits.message) return error.MessageTooLarge;
        if (sub_list) |offset| {
            if (offset > size) return error.InvalidOffset;
        }
        const total = std.math.add(usize, self.mode.size(), size) catch return error.IntegerOverflow;
        if (self.buffered < total) return null;
        const result: Peek = .{ .size = total, .message = .{
            .serial = serial,
            .kind = kind,
            .sub_list = sub_list,
            .body = try self.bodySlice(self.mode.size(), size),
        } };
        self.cached = result;
        return result;
    }
    fn consume(self: *Framer, count: usize) void {
        var remaining = count;
        while (remaining > 0) {
            const segment = self.head.?;
            const available = segment.slice.bytes().len - self.head_offset;
            if (remaining < available) {
                self.head_offset += remaining;
                break;
            }
            remaining -= available;
            self.head = segment.next;
            self.head_offset = 0;
            self.segment_count -= 1;
            segment.slice.release();
            self.allocator.destroy(segment);
        }
        self.buffered -= count;
        if (self.head == null) self.tail = null;
        if (self.cached) |cached| cached.message.deinit();
        self.cached = null;
    }
    pub fn nextMessage(self: *Framer) !?Message {
        const peeked = (try self.peek()) orelse return null;
        var message = peeked.message;
        message.body = message.body.clone();
        self.consume(peeked.size);
        return message;
    }
    pub fn nextBatch(self: *Framer, maximum: usize) !?Batch {
        const peeked = (try self.peek()) orelse return null;
        const batch = try Batch.parse(self.allocator, peeked.message, maximum);
        self.consume(peeked.size);
        return batch;
    }
};
