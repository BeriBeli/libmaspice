const std = @import("std");
const t = std.testing;
const w = @import("spice").bytes;
const p = @import("spice").protocol;
const link = @import("spice").link;
const flow = @import("spice").flow;
const ticket = @import("spice").ticket;
const request: link.Request = .{ .connection_id = 0x12345678, .channel_type = 1, .channel_id = 0, .common = &.{11}, .channel = &.{13} };
const header = [_]u8{ 0x52, 0x45, 0x44, 0x51, 2, 0, 0, 0, 2, 0, 0, 0, 186, 0, 0, 0 };
fn reply(common: u32) [186]u8 {
    var bytes: [186]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[166..170], 1, .little);
    std.mem.writeInt(u32, bytes[170..174], 1, .little);
    std.mem.writeInt(u32, bytes[174..178], 178, .little);
    std.mem.writeInt(u32, bytes[178..182], common, .little);
    std.mem.writeInt(u32, bytes[182..186], 13, .little);
    return bytes;
}
fn encrypt(password: []const u8, key: []const u8) ticket.Error![128]u8 {
    if (!std.mem.eql(u8, password, "test") or key.len != 162) return error.EncryptionFailed;
    return @splat(0xa5);
}
fn failEncrypt(_: []const u8, _: []const u8) ticket.Error![128]u8 {
    return error.EncryptionFailed;
}

fn transcript(allocator: std.mem.Allocator) !void {
    var state: link.Handshake = .{ .allocator = allocator };
    defer state.deinit();
    var output: w.Writer = .{ .allocator = allocator, .limit = 1024 };
    defer output.deinit();
    try state.begin(request, &output);
    // Independent little-endian request fixture from the Swift LinkRequest.
    try t.expectEqualSlices(u8, &.{ 0x52, 0x45, 0x44, 0x51, 2, 0, 0, 0, 2, 0, 0, 0, 26, 0, 0, 0, 0x78, 0x56, 0x34, 0x12, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 18, 0, 0, 0, 11, 0, 0, 0, 13, 0, 0, 0 }, output.bytes.items);
    output.bytes.clearRetainingCapacity();
    try t.expectEqual(@as(usize, 16), try state.expectedReadSize());
    try state.acceptHeader(&header);
    try t.expectEqual(@as(usize, 186), try state.expectedReadSize());
    try state.acceptReplyWith(&reply(11), "test", &output, encrypt);
    try t.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, output.bytes.items[0..4]);
    try t.expectEqualSlices(u8, &@as([128]u8, @splat(0xa5)), output.bytes.items[4..]);
    try t.expectError(error.InvalidState, state.result());
    try state.acceptResult(&.{ 0, 0, 0, 0 });
    const result = try state.result();
    try t.expectEqual(.mini, result.mode);
    try t.expectEqualSlices(u32, &.{11}, result.common);
    try t.expectEqualSlices(u32, &.{13}, result.channel);
    state.cancel();
    state.cancel();
    try t.expectError(error.InvalidState, state.result());
    state.restart();
    output.bytes.clearRetainingCapacity();
    try state.begin(request, &output);
}

test "handshake exact transcript, authenticated capability lifetime and all allocation failures" {
    try t.checkAllAllocationFailures(t.allocator, transcript, .{});
}

test "legacy auth omits selection; rejected result releases negotiated state" {
    var state: link.Handshake = .{ .allocator = t.allocator };
    defer state.deinit();
    var output: w.Writer = .{ .allocator = t.allocator, .limit = 1024 };
    defer output.deinit();
    try state.begin(request, &output);
    output.bytes.clearRetainingCapacity();
    try state.acceptHeader(&header);
    try state.acceptReplyWith(&reply(0), "test", &output, encrypt);
    try t.expectEqual(@as(usize, 128), output.bytes.items.len);
    try t.expectError(error.AuthenticationRejected, state.acceptResult(&.{ 7, 0, 0, 0 }));
    try t.expectEqual(@as(?u32, 7), state.rejection_code);
    try t.expectEqual(@as(?link.Negotiated, null), state.negotiated);
}

test "header safety bounds are checked before accepting reply storage" {
    var state: link.Handshake = .{ .allocator = t.allocator };
    defer state.deinit();
    var output: w.Writer = .{ .allocator = t.allocator, .limit = 1024 };
    defer output.deinit();
    for (0..header.len) |end| {
        state.restart();
        output.bytes.clearRetainingCapacity();
        try state.begin(request, &output);
        try t.expectError(error.Truncated, state.acceptHeader(header[0..end]));
        try t.expectEqual(.failed, state.state);
    }
    for ([_]u32{ 177, 64 * 1024 * 1024 + 1, 0xffffffff }) |size| {
        state.restart();
        output.bytes.clearRetainingCapacity();
        try state.begin(request, &output);
        var bad = header;
        std.mem.writeInt(u32, bad[12..16], size, .little);
        if (state.acceptHeader(&bad)) |_| return error.AcceptedInvalidSize else |_| {}
        try t.expectEqual(.failed, state.state);
    }
}

test "bad capability range unsupported auth crypto failure and output exhaustion never emit ticket" {
    var state: link.Handshake = .{ .allocator = t.allocator };
    defer state.deinit();
    var output: w.Writer = .{ .allocator = t.allocator, .limit = 1024 };
    defer output.deinit();
    for (0..4) |scenario| {
        state.restart();
        output.bytes.clearRetainingCapacity();
        try state.begin(request, &output);
        output.bytes.clearRetainingCapacity();
        try state.acceptHeader(&header);
        var body = reply(if (scenario == 1) 1 else 11);
        if (scenario == 0) std.mem.writeInt(u32, body[174..178], 184, .little);
        if (scenario == 3) output.limit = 131;
        const operation: *const fn ([]const u8, []const u8) ticket.Error![128]u8 = if (scenario == 2) failEncrypt else encrypt;
        if (state.acceptReplyWith(&body, "test", &output, operation)) |_| return error.AcceptedFailure else |_| {}
        try t.expectEqual(.failed, state.state);
        try t.expectEqual(@as(usize, 0), output.bytes.items.len);
        try t.expectEqual(@as(?link.Negotiated, null), state.negotiated);
    }
}

test "physical batch ACK windows and generation reset" {
    var ack: flow.Ack = .{};
    try t.expect(!ack.didProcessBatch());
    ack.configure(7, 2);
    try t.expect(!ack.didProcessBatch());
    try t.expect(ack.didProcessBatch());
    try t.expect(!ack.didProcessBatch());
    ack.configure(8, 2);
    try t.expect(!ack.didProcessBatch());
    try t.expect(ack.didProcessBatch());
    ack.configure(9, 0);
    try t.expect(!ack.didProcessBatch());
}

fn window(size: u32, timeout: u32) flow.StreamReportWindow {
    return .{ .activation = .{ .streamID = 7, .uniqueID = 42, .maximumWindowSize = size, .timeoutMilliseconds = timeout } };
}
test "STREAM_REPORT tracks arrival margins, multimedia wrap and reset with exact encoded bytes" {
    var state = window(2, 1000);
    try t.expectEqual(@as(?p.SpiceMsgcDisplayStreamReport, null), state.record(0xffffffff, -1, 0xffffffff, 0));
    const report = state.record(3, 5, 60, 0).?;
    var output: w.Writer = .{ .allocator = t.allocator, .limit = 32 };
    defer output.deinit();
    try report.encode(&output);
    try t.expectEqualSlices(u8, &.{ 7, 0, 0, 0, 42, 0, 0, 0, 255, 255, 255, 255, 3, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0, 60, 0, 0, 0 }, output.bytes.items);
    try t.expectEqual(@as(?p.SpiceMsgcDisplayStreamReport, null), state.record(4, 0, 0xffffffff, 0));
    const next = state.record(5, 0, 0xffffffff, 0).?;
    try t.expectEqual(@as(u32, 4), next.startFrameMultimediaTime);
    try t.expectEqual(@as(u32, 0), next.dropCount);
}

test "STREAM_REPORT monotonic timeout, three consecutive late arrivals, zero thresholds" {
    var state = window(0xffffffff, 100);
    try t.expect(state.record(100, 5, 0xffffffff, 10) == null);
    try t.expect(state.record(1000000, 5, 0xffffffff, 109) == null);
    try t.expectEqual(@as(u32, 3), state.record(2, 5, 0xffffffff, 110).?.frameCount);
    try t.expect(state.record(3, 5, 0xffffffff, 10000) == null);
    state = window(0xffffffff, 0xffffffff);
    for ([_]i32{ -1, -2, 0, -3, -4 }) |margin| try t.expect(state.record(1, margin, 0xffffffff, 0) == null);
    const report = state.record(2, -5, 0xffffffff, 0).?;
    try t.expectEqual(@as(u32, 6), report.frameCount);
    try t.expectEqual(@as(u32, 5), report.dropCount);
    state = window(0, 0xffffffff);
    try t.expectEqual(@as(u32, 1), state.record(1, 0, 0xffffffff, 0).?.frameCount);
    state = window(0xffffffff, 0);
    try t.expectEqual(@as(u32, 1), state.record(1, 0, 0xffffffff, 0).?.frameCount);
}

test "generated channel IDs borrow validated bytes and encoding fails transactionally" {
    const bytes = [_]u8{ 3, 0, 0, 0, 1, 0, 2, 1, 4, 7 };
    const value = try p.SpiceMsgMainChannelsList.decodeExact(&bytes);
    try t.expectEqual(@as(usize, 3), value.channels.count());
    try t.expectEqual(@as(u8, 7), (try value.channels.at(2)).id);
    try t.expectError(error.InvalidOffset, value.channels.at(3));
    var output: w.Writer = .{ .allocator = t.allocator, .limit = 9 };
    defer output.deinit();
    try t.expectError(error.MessageTooLarge, value.encode(&output));
    try t.expectEqual(@as(usize, 0), output.bytes.items.len);
}
