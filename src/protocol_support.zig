const wire = @import("bytes.zig");
const std = @import("std");

/// Borrowed packed channel IDs. Explicit byte access avoids alignment and
/// native struct-layout dependencies; the receive owner must remain alive.
pub const ChannelIDs = struct {
    bytes: []const u8,
    pub fn init(bytes: []const u8) !ChannelIDs {
        if (bytes.len % 2 != 0) return error.InvalidSize;
        if (bytes.len / 2 > std.math.maxInt(u32)) return error.IntegerOverflow;
        return .{ .bytes = bytes };
    }
    pub fn count(self: ChannelIDs) usize {
        return self.bytes.len / 2;
    }
    pub fn at(self: ChannelIDs, index: usize) !struct { kind: u8, id: u8 } {
        if (index >= self.count()) return error.InvalidOffset;
        return .{ .kind = self.bytes[index * 2], .id = self.bytes[index * 2 + 1] };
    }
    pub fn decode(reader: *wire.Reader) !ChannelIDs {
        const start = reader.offset;
        errdefer reader.offset = start;
        const n = try reader.read(u32);
        if (n > reader.remaining() / 2) return error.InvalidSize;
        return init(try reader.take(@as(usize, n) * 2));
    }
    pub fn encode(self: ChannelIDs, writer: *wire.Writer) !void {
        _ = try init(self.bytes);
        const start = writer.bytes.items.len;
        errdefer writer.bytes.items.len = start;
        try writer.write(u32, @intCast(self.count()));
        try writer.append(self.bytes);
    }
};
