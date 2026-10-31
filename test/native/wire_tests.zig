const std = @import("std");
const w = @import("spice").bytes;
const f = @import("spice").framer;
const t = std.testing;
const a = t.allocator;

// Literal fixture from the existing Swift full-header contract: the offset
// table reverses physical submessage order and the main prefix executes last.
const fixture = [_]u8{
    123,  0,    0, 0,    0,  0, 0, 0, 107, 0, 27, 0, 0,    0, 2, 0, 0, 0,
    0xa1, 0xa2, 2, 0,    21, 0, 0, 0, 12,  0, 0,  0, 0x91, 1, 3, 0, 0, 0,
    1,    2,    3, 0x92, 1,  0, 0, 0, 0,
};

test "byte reads are little endian, signed, unaligned and transactional" {
    var reader = try w.Reader.init(&.{ 0xff, 0x34, 0x12, 0xfe, 0xff, 0xff, 0xff }, 1);
    try t.expectEqual(@as(u16, 0x1234), try reader.read(u16));
    try t.expectError(error.Truncated, reader.read(u64));
    try t.expectEqual(@as(usize, 3), reader.offset);
    try t.expectEqual(@as(i32, -2), try reader.read(i32));
    try reader.finish();
    try t.expectError(error.InvalidOffset, w.Reader.init(&.{1}, 2));
    try t.expectError(error.InvalidOffset, w.resolve(32, 24, 9));
    try t.expectError(error.InvalidOffset, w.resolve(32, std.math.maxInt(u64), 1));
    try t.expectError(error.IntegerOverflow, w.resolve(32, std.math.maxInt(isize), std.math.maxInt(usize)));
}

test "writer bounds fail without partial scalar writes" {
    var writer: w.Writer = .{ .allocator = a, .limit = 7 };
    defer writer.deinit();
    try writer.write(u16, 0x1234);
    try writer.write(i32, -2);
    try t.expectError(error.MessageTooLarge, writer.write(u16, 42));
    try t.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xfe, 0xff, 0xff, 0xff }, writer.bytes.items);
}

fn verifyBatch(batch: f.Batch) !void {
    try t.expectEqual(@as(?u64, 123), batch.message.serial);
    try t.expectEqual(@as(usize, 3), batch.logical.len);
    try t.expectEqual(@as(u16, 402), batch.logical[0].kind);
    try t.expectEqual(@as(u16, 401), batch.logical[1].kind);
    try t.expectEqual(@as(u16, 107), batch.logical[2].kind);
    try t.expectEqualSlices(u8, &.{}, batch.body(0));
    try t.expectEqualSlices(u8, &.{ 1, 2, 3 }, batch.body(1));
    try t.expectEqualSlices(u8, &.{ 0xa1, 0xa2 }, batch.body(2));
    for (batch.logical, 0..) |logical, i| try t.expectEqual(@as(u1, @intFromBool(i == 2)), logical.acknowledgmentCount(i, batch.logical.len));
}

test "every split preserves list order, serial, main prefix and one ACK" {
    for (0..fixture.len + 1) |split| {
        var framer: f.Framer = .{ .allocator = a, .mode = .full };
        defer framer.deinit();
        try framer.append(fixture[0..split]);
        if (split < fixture.len) {
            try t.expectEqual(@as(?f.Batch, null), try framer.nextBatch(4096));
            try framer.append(fixture[split..]);
        }
        const batch = (try framer.nextBatch(4096)).?;
        defer batch.deinit();
        try verifyBatch(batch);
        try t.expectEqual(@as(usize, 0), framer.buffered);
        framer.reset();
        try verifyBatch(batch); // Owned body survives reset.
    }
}

test "single owner has no body copy, shared slice outlives input and framer" {
    const owner = try w.Slice.copy(a, &fixture);
    var framer: f.Framer = .{ .allocator = a, .mode = .full };
    try framer.appendShared(owner);
    const batch = (try framer.nextBatch(4096)).?;
    defer batch.deinit();
    try t.expect(batch.message.body.storage == owner.storage);
    owner.release();
    try t.expectEqual(@as(u64, 0), framer.copy_bytes);
    try t.expectEqual(fixture.len, batch.message.body.retainedBytes());
    framer.deinit();
    try verifyBatch(batch);
}

test "malformed duplicate offsets never consume or repeatedly coalesce" {
    var malformed = fixture;
    @memcpy(malformed[26..30], malformed[22..26]);
    var framer: f.Framer = .{ .allocator = a, .mode = .full };
    defer framer.deinit();
    for (malformed) |byte| try framer.append(&.{byte});
    for (0..3) |_| {
        try t.expectError(error.InvalidOffset, framer.nextBatch(4096));
        try t.expectEqual(fixture.len, framer.buffered);
        try t.expectEqual(@as(u64, 1), framer.coalesces);
        try t.expectEqual(@as(u64, 27), framer.copy_bytes);
    }
    framer.reset();
    try framer.append(&fixture);
    const batch = (try framer.nextBatch(4096)).?;
    defer batch.deinit();
    try verifyBatch(batch);
}

test "mini type LIST stays a plain message; zero body and multiple messages" {
    var framer: f.Framer = .{ .allocator = a, .mode = .mini };
    defer framer.deinit();
    try framer.append(&.{ 8, 0, 0, 0, 0, 0, 103, 0, 2, 0, 0, 0, 0xaa, 0xbb });
    const first = (try framer.nextBatch(4096)).?;
    defer first.deinit();
    try t.expectEqual(@as(usize, 1), first.logical.len);
    try t.expectEqual(@as(?u64, null), first.message.serial);
    try t.expectEqual(@as(usize, 0), first.body(0).len);
    const second = (try framer.nextMessage()).?;
    defer second.deinit();
    try t.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, second.body.bytes());
    try t.expectEqual(@as(?f.Message, null), try framer.nextMessage());
}

test "empty full LIST is one physical ACK with no logical messages" {
    var framer: f.Framer = .{ .allocator = a, .mode = .full };
    defer framer.deinit();
    try framer.append(&.{ 1, 0, 0, 0, 0, 0, 0, 0, 8, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    const batch = (try framer.nextBatch(0)).?;
    defer batch.deinit();
    try t.expectEqual(@as(usize, 0), batch.logical.len);
    try t.expectEqual(1, f.Batch.acknowledgment_count);
}

test "limits reject before ownership allocation and reset restores capacity" {
    var framer: f.Framer = .{ .allocator = a, .mode = .mini, .limits = .{ .message = 2, .buffered = 8, .segments = 2 } };
    defer framer.deinit();
    try framer.append(&.{ 1, 0, 3, 0, 0, 0 });
    try t.expectError(error.MessageTooLarge, framer.nextMessage());
    try t.expectEqual(@as(usize, 6), framer.buffered);
    try t.expectError(error.MessageTooLarge, framer.append(&.{ 1, 2, 3 }));
    try framer.append(&.{1});
    try framer.append(&.{});
    try t.expectError(error.TooManySegments, framer.append(&.{1}));
    framer.reset();
    try framer.append(&.{ 1, 0, 0, 0, 0, 0 });
    const msg = (try framer.nextMessage()).?;
    msg.deinit();
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var framer: f.Framer = .{ .allocator = allocator, .mode = .full };
    defer framer.deinit();
    try framer.append(fixture[0..23]);
    try framer.append(fixture[23..]);
    const batch = (try framer.nextBatch(4096)).?;
    defer batch.deinit();
    try verifyBatch(batch);
    var writer: w.Writer = .{ .allocator = allocator, .limit = 16 };
    defer writer.deinit();
    try writer.write(u64, 42);
}

test "every allocation failure cleans up across append coalesce batch writer" {
    try t.checkAllAllocationFailures(a, allocationScenario, .{});
}

test "maximum 4096 submessages and one above configured limit" {
    var writer: w.Writer = .{ .allocator = a, .limit = 50000 };
    defer writer.deinit();
    try writer.write(u64, 1);
    try writer.write(u16, 8);
    try writer.write(u32, 4096 * 10 + 2);
    try writer.write(u32, 0);
    try writer.write(u16, 4096);
    for (0..4096) |i| try writer.write(u32, @intCast(2 + 4096 * 4 + i * 6));
    for (0..4096) |_| {
        try writer.write(u16, 3);
        try writer.write(u32, 0);
    }
    var framer: f.Framer = .{ .allocator = a, .mode = .full };
    defer framer.deinit();
    try framer.append(writer.bytes.items);
    try t.expectError(error.MessageTooLarge, framer.nextBatch(4095));
    const batch = (try framer.nextBatch(4096)).?;
    defer batch.deinit();
    try t.expectEqual(@as(usize, 4096), batch.logical.len);
}

test "actual default 128MiB buffered byte and 4096 segment ceilings restore capacity" {
    var framer: f.Framer = .{ .allocator = a, .mode = .mini };
    defer framer.deinit();
    const bytes = try w.Slice.allocate(a, 128 * 1024 * 1024);
    defer bytes.release();
    @memset(bytes.storage.bytes, 0);
    try framer.appendShared(bytes);
    try t.expectEqual(@as(usize, 128 * 1024 * 1024), framer.buffered);
    try t.expectError(error.MessageTooLarge, framer.append(&.{1}));
    framer.reset();
    for (0..4096) |_| try framer.append(&.{0});
    try t.expectError(error.TooManySegments, framer.append(&.{0}));
    const message = (try framer.nextMessage()).?;
    message.deinit();
    try framer.append(&.{0});
    try t.expectEqual(@as(usize, 4091), framer.segment_count);
}

fn allocationRetryTest(allocator: std.mem.Allocator) !void {
    var framer: f.Framer = .{ .allocator = allocator, .mode = .full };
    defer framer.deinit();
    framer.append(&fixture) catch |err| {
        try t.expectEqual(@as(usize, 0), framer.buffered);
        try t.expectEqual(@as(usize, 0), framer.segment_count);
        return err;
    };
    const batch = framer.nextBatch(4096) catch |err| {
        try t.expectEqual(fixture.len, framer.buffered);
        return err;
    };
    defer batch.?.deinit();
}
test "allocation failures preserve queued frame or leave append unchanged" {
    try t.checkAllAllocationFailures(a, allocationRetryTest, .{});
}
