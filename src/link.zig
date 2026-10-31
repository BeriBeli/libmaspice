//! Exact-I/O handshake state machine. The transport must complete each emitted
//! write before reading the requested next unit; failed I/O calls cancel().
//! This module owns negotiation and authentication sequencing, not a socket.
const std = @import("std");
const wire = @import("bytes.zig");
const p = @import("generated.zig");
const ticket = @import("ticket.zig");
const Mode = @import("framer.zig").Mode;

pub const Request = struct {
    connection_id: u32,
    channel_type: u8,
    channel_id: u8,
    common: []const u32,
    channel: []const u32,

    pub fn encode(self: Request, writer: *wire.Writer) !void {
        const start = writer.bytes.items.len;
        errdefer writer.bytes.items.len = start;
        const words = std.math.add(usize, self.common.len, self.channel.len) catch return error.IntegerOverflow;
        const bytes = std.math.mul(usize, words, 4) catch return error.IntegerOverflow;
        const body = std.math.add(usize, p.SpiceLinkMessage.minimum_wire_size, bytes) catch return error.IntegerOverflow;
        if (body > std.math.maxInt(u32)) return error.IntegerOverflow;
        try (p.SpiceLinkHeader{ .magic = 0x51444552, .majorVersion = 2, .minorVersion = 2, .size = @intCast(body) }).encode(writer);
        try (p.SpiceLinkMessage{
            .connectionID = self.connection_id,
            .channelType = self.channel_type,
            .channelID = self.channel_id,
            .commonCapabilityWordCount = @intCast(self.common.len),
            .channelCapabilityWordCount = @intCast(self.channel.len),
            .capabilitiesOffset = p.SpiceLinkMessage.minimum_wire_size,
        }).encode(writer);
        for (self.common) |word| try writer.write(u32, word);
        for (self.channel) |word| try writer.write(u32, word);
    }
};

pub fn contains(words: []const u32, bit: usize) bool {
    const index = bit / 32;
    return index < words.len and words[index] & (@as(u32, 1) << @as(u5, @intCast(bit % 32))) != 0;
}

pub const Negotiated = struct {
    allocator: std.mem.Allocator,
    words: []u32,
    common_count: usize,
    pub fn deinit(self: Negotiated) void {
        self.allocator.free(self.words);
    }
    pub fn common(self: Negotiated) []const u32 {
        return self.words[0..self.common_count];
    }
    pub fn channel(self: Negotiated) []const u32 {
        return self.words[self.common_count..];
    }
    pub fn mode(self: Negotiated) Mode {
        return if (contains(self.common(), 3)) .mini else .full;
    }
};

pub const Handshake = struct {
    pub const State = enum { idle, reply_header, reply_body, authentication_result, ready, cancelled, failed };
    allocator: std.mem.Allocator,
    maximum_reply_size: usize = 64 * 1024 * 1024,
    state: State = .idle,
    reply_size: usize = 0,
    negotiated: ?Negotiated = null,
    rejection_code: ?u32 = null,

    pub fn deinit(self: *Handshake) void {
        self.cancel();
    }
    pub fn cancel(self: *Handshake) void {
        if (self.negotiated) |value| value.deinit();
        self.negotiated = null;
        self.reply_size = 0;
        self.state = .cancelled;
    }
    /// Explicit restart invalidates any previously borrowed negotiated views.
    pub fn restart(self: *Handshake) void {
        self.cancel();
        self.rejection_code = null;
        self.state = .idle;
    }
    pub fn begin(self: *Handshake, request: Request, output: *wire.Writer) !void {
        if (self.state != .idle) return error.InvalidState;
        try request.encode(output);
        self.state = .reply_header;
    }
    pub fn expectedReadSize(self: Handshake) !usize {
        return switch (self.state) {
            .reply_header => p.SpiceLinkHeader.minimum_wire_size,
            .reply_body => self.reply_size,
            .authentication_result => p.SpiceLinkResult.minimum_wire_size,
            else => error.InvalidState,
        };
    }
    pub fn acceptHeader(self: *Handshake, bytes: []const u8) !void {
        if (self.state != .reply_header) return error.InvalidState;
        errdefer self.state = .failed;
        const header = try p.SpiceLinkHeader.decodeExact(bytes);
        if (header.magic != 0x51444552) return error.InvalidMagic;
        if (header.majorVersion != 2) return error.UnsupportedVersion;
        if (header.size < p.SpiceLinkReply.minimum_wire_size) return error.InvalidSize;
        if (header.size > self.maximum_reply_size) return error.MessageTooLarge;
        self.reply_size = header.size;
        self.state = .reply_body;
    }
    pub fn acceptReply(self: *Handshake, bytes: []const u8, password: []const u8, output: *wire.Writer) !void {
        try self.acceptReplyWith(bytes, password, output, ticket.encrypt);
    }
    /// Injectable encryption supports deterministic peer transcripts. Production
    /// callers use acceptReply, which always invokes the native RSA operation.
    pub fn acceptReplyWith(self: *Handshake, bytes: []const u8, password: []const u8, output: *wire.Writer, encrypt: *const fn ([]const u8, []const u8) ticket.Error![128]u8) !void {
        if (self.state != .reply_body) return error.InvalidState;
        errdefer self.state = .failed;
        if (bytes.len != self.reply_size) return error.InvalidSize;
        var reader = try wire.Reader.init(bytes, 0);
        const reply = try p.SpiceLinkReply.decode(&reader);
        if (reply.@"error" != 0) {
            self.rejection_code = reply.@"error";
            return error.LinkRejected;
        }
        const count = try std.math.add(usize, reply.commonCapabilityWordCount, reply.channelCapabilityWordCount);
        const length = try std.math.mul(usize, count, 4);
        const range = try wire.resolve(bytes.len, reply.capabilitiesOffset, length);
        var caps = try wire.Reader.init(bytes[range.start..range.end], 0);
        const words = try self.allocator.alloc(u32, count);
        errdefer self.allocator.free(words);
        for (words) |*word| word.* = try caps.read(u32);
        const common = words[0..reply.commonCapabilityWordCount];
        const selects_auth = contains(common, 0);
        if (selects_auth and !contains(common, 1)) return error.UnsupportedAuthentication;
        const encrypted = try encrypt(password, &reply.publicKey);
        const start = output.bytes.items.len;
        errdefer output.bytes.items.len = start;
        if (selects_auth) try output.write(u32, 1);
        try output.append(&encrypted);
        self.negotiated = .{ .allocator = self.allocator, .words = words, .common_count = reply.commonCapabilityWordCount };
        self.state = .authentication_result;
    }
    pub fn acceptResult(self: *Handshake, bytes: []const u8) !void {
        if (self.state != .authentication_result) return error.InvalidState;
        errdefer {
            if (self.negotiated) |value| value.deinit();
            self.negotiated = null;
            self.state = .failed;
        }
        const reply_result = try p.SpiceLinkResult.decodeExact(bytes);
        if (reply_result.@"error" != 0) {
            self.rejection_code = reply_result.@"error";
            return error.AuthenticationRejected;
        }
        self.state = .ready;
    }
    /// The returned capability views are borrowed until cancel/restart/deinit.
    /// They are not exposed before a successful authentication result.
    pub fn result(self: Handshake) !struct { common: []const u32, channel: []const u32, mode: Mode } {
        if (self.state != .ready) return error.InvalidState;
        const value = self.negotiated.?;
        return .{ .common = value.common(), .channel = value.channel(), .mode = value.mode() };
    }
};

/// Runs the real transport handshake. Credentials are borrowed only for this
/// call; all failure paths cancel the transport and release negotiation storage.
pub fn perform(allocator: std.mem.Allocator, transport: *@import("transport.zig").Transport, request: Request, password: []const u8) !Negotiated {
    errdefer transport.cancel();
    try transport.connect();
    var state: Handshake = .{ .allocator = allocator };
    defer state.deinit();
    var output: wire.Writer = .{ .allocator = allocator, .limit = 64 * 1024 * 1024 };
    defer output.deinit();
    try state.begin(request, &output);
    try transport.write(output.bytes.items);
    var header: [p.SpiceLinkHeader.minimum_wire_size]u8 = undefined;
    try transport.readExactly(&header);
    try state.acceptHeader(&header);
    const reply = try allocator.alloc(u8, try state.expectedReadSize());
    defer allocator.free(reply);
    try transport.readExactly(reply);
    output.bytes.clearRetainingCapacity();
    try state.acceptReply(reply, password, &output);
    try transport.write(output.bytes.items);
    var result: [4]u8 = undefined;
    try transport.readExactly(&result);
    try state.acceptResult(&result);
    const negotiated = state.negotiated.?;
    state.negotiated = null;
    return negotiated;
}
