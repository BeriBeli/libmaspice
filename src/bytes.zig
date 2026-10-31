//! Synchronous borrowed readers and bounded writers. Readers must not outlive
//! their input owner. No native struct layout is used to interpret wire bytes.
const std = @import("std");
pub const Error = error{ Truncated, InvalidOffset, IntegerOverflow, MessageTooLarge, TooManySegments, TrailingBytes, InvalidSize };

pub const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn init(bytes: []const u8, offset: usize) Error!Reader {
        if (offset > bytes.len) return error.InvalidOffset;
        return .{ .bytes = bytes, .offset = offset };
    }
    pub fn remaining(self: Reader) usize {
        return self.bytes.len - self.offset;
    }
    pub fn read(self: *Reader, comptime T: type) Error!T {
        const bytes = try self.take(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
    }
    pub fn take(self: *Reader, count: usize) Error![]const u8 {
        if (count > self.remaining()) return error.Truncated;
        const start = self.offset;
        self.offset += count;
        return self.bytes[start..self.offset];
    }
    pub fn finish(self: Reader) Error!void {
        if (self.remaining() != 0) return error.TrailingBytes;
    }
};

pub const Writer = struct {
    allocator: std.mem.Allocator,
    limit: usize,
    bytes: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Writer) void {
        self.bytes.deinit(self.allocator);
        self.bytes = .empty;
    }
    pub fn write(self: *Writer, comptime T: type, value: T) !void {
        var buffer: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buffer, value, .little);
        try self.append(&buffer);
    }
    pub fn append(self: *Writer, bytes: []const u8) !void {
        if (bytes.len > self.limit - self.bytes.items.len) return error.MessageTooLarge;
        try self.bytes.appendSlice(self.allocator, bytes);
    }
};

pub const Range = struct { start: usize, end: usize };
pub fn resolve(message_size: usize, address: u64, length: usize) Error!Range {
    // Match the existing wire contract: protocol addresses must fit the host's
    // signed indexing domain before checking addition or the message range.
    if (address > std.math.maxInt(isize)) return error.InvalidOffset;
    const start = std.math.cast(usize, address) orelse return error.InvalidOffset;
    const end = std.math.add(usize, start, length) catch return error.IntegerOverflow;
    if (start > message_size or end > message_size) return error.InvalidOffset;
    return .{ .start = start, .end = end };
}

/// An immutable shared allocation. Every owning value must be released once;
/// use clone/subslice to acquire ownership, never plain assignment then release
/// both copies. Atomic references allow immutable slices to cross executors.
/// The allocator must support frees on every executor receiving a slice.
pub const Slice = struct {
    const Storage = struct {
        allocator: std.mem.Allocator,
        refs: std.atomic.Value(usize),
        bytes: []u8,
    };
    storage: *Storage,
    range: Range,

    pub fn copy(allocator: std.mem.Allocator, source: []const u8) !Slice {
        const result = try allocate(allocator, source.len);
        @memcpy(result.storage.bytes, source);
        return result;
    }
    // Uninitialized bytes remain private to the framer until filled.
    pub fn allocate(allocator: std.mem.Allocator, size: usize) !Slice {
        const storage = try allocator.create(Storage);
        errdefer allocator.destroy(storage);
        storage.* = .{ .allocator = allocator, .refs = .init(1), .bytes = try allocator.alloc(u8, size) };
        return .{ .storage = storage, .range = .{ .start = 0, .end = size } };
    }
    pub fn bytes(self: Slice) []const u8 {
        return self.storage.bytes[self.range.start..self.range.end];
    }
    pub fn retainedBytes(self: Slice) usize {
        return self.storage.bytes.len;
    }
    pub fn clone(self: Slice) Slice {
        const old = self.storage.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old > 0 and old < std.math.maxInt(usize));
        return self;
    }
    pub fn subslice(self: Slice, start: usize, length: usize) Error!Slice {
        const range = try resolve(self.bytes().len, start, length);
        var result = self.clone();
        result.range = .{ .start = self.range.start + range.start, .end = self.range.start + range.end };
        return result;
    }
    pub fn release(self: Slice) void {
        if (self.storage.refs.fetchSub(1, .acq_rel) == 1) {
            const allocator = self.storage.allocator;
            allocator.free(self.storage.bytes);
            allocator.destroy(self.storage);
        }
    }
};
