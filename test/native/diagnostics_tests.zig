const std = @import("std");
const t = std.testing;
const s = @import("spice");
test "timing boundaries merge wrapping and invalid values" {
    var h: s.timing.Histogram = .{};
    try t.expectEqual(s.timing.Summary{}, h.summary());
    for (s.timing.Histogram.upper_ms) |value| h.record(value);
    h.record(6000);
    try t.expectEqual(@as(u64, 21), h.summary().sample_count);
    try t.expectEqual(@as(?f64, 5000), h.summary().p95_ms);
    var other: s.timing.Histogram = .{};
    other.record(std.math.nan(f64));
    other.record(std.math.inf(f64));
    other.record(-1);
    other.duration(0, 500_000_000_000_000);
    h.accumulate(other);
    try t.expectEqual(@as(u64, 25), h.summary().sample_count);
    try t.expectEqual(@as(u64, 4), h.buckets[0]);
    try t.expectEqual(@as(?f64, 6000), h.summary().maximum_ms);
    other.count = std.math.maxInt(u64);
    other.record(0);
    try t.expectEqual(s.timing.Summary{}, other.summary());
}
test "presentation reset ignores old GPU callbacks and distinguishes completion from display" {
    var recorder: s.presentation_diagnostics.Recorder = .{};
    defer recorder.deinit();
    const old = recorder.currentEpoch();
    recorder.presented(true, old);
    recorder.fallback(.missing_iosurface);
    recorder.interval(.commit_to_completion, 100, 2_000_100, old);
    try t.expectEqual(@as(u64, 1), recorder.snapshot().count(.metal_presented));
    try t.expectEqual(@as(u64, 0), recorder.snapshot().latency(.request_to_presented).sample_count);
    recorder.reset();
    recorder.presented(true, old);
    recorder.add(.metal_errors, 1, old);
    recorder.record(.request_to_presented, 80, old);
    try t.expectEqual(@as(u64, 0), recorder.snapshot().count(.metal_presented));
    recorder.presented(false, recorder.currentEpoch());
    recorder.fallback(.metal_command_failure);
    recorder.interval(.request_to_presented, 100, 3_000_100, null);
    const result = recorder.snapshot();
    try t.expectEqual(@as(u64, 1), result.count(.metal_presented));
    try t.expectEqual(@as(u64, 0), result.count(.advanced_video_presented));
    try t.expectEqual(@as(?f64, 3), result.latency(.request_to_presented).p95_ms);
    try t.expectEqual(@as(u64, 1), result.fallback_frames);
    try t.expectEqual(s.presentation_diagnostics.Fallback.metal_command_failure, result.last_fallback.?);
}
test "media time uses callback-local calibration and rejects impossible timestamps" {
    try t.expectEqual(@as(?u64, 8_000_000_000), s.timing.mediaTimestamp(20, 22, 10_000_000_000));
    try t.expectEqual(@as(?u64, 108_000_000_000), s.timing.mediaTimestamp(20, 22, 110_000_000_000));
    try t.expectEqual(@as(?u64, null), s.timing.mediaTimestamp(23, 22, 10));
    try t.expectEqual(@as(?u64, null), s.timing.mediaTimestamp(0, 22, 10));
    try t.expectEqual(@as(?u64, null), s.timing.mediaTimestamp(1, std.math.inf(f64), 10));
    try t.expectEqual(@as(?u64, null), s.timing.mediaTimestamp(1, 22, 10));
}

fn validRecord() s.interaction_record.Record {
    return .{ .pair_id = "a", .version = "zig", .run_id = "run", .order = 1, .action_class = .click, .token = "0123456789abcdef", .scheduled_ns = 1, .host_input_ns = 2, .send_started_ns = 3, .send_completed_ns = 100, .guest_received_ns = 9000, .guest_marker_drawn_ns = 9010, .marker_revision = 9, .marker_checksum = "aabbccdd", .display_receive_ns = 4, .surface_ready_ns = 5, .selected_revision_ready_ns = 6, .selection_ns = 7, .metal_commit_ns = 8, .presented_ns = 9, .display_channel_id = 0, .surface_id = 1, .surface_generation = 2, .desktop_generation = 3, .frame_revision = 4, .delivery_sequence = 5 };
}
fn roundtrip(allocator: std.mem.Allocator) !void {
    const encoded = try validRecord().encode(allocator);
    defer allocator.free(encoded);
    const decoded = try s.interaction_record.decode(allocator, encoded);
    defer decoded.deinit();
    try t.expect(decoded.value.valid);
    try t.expectEqual(@as(?u64, 0), decoded.value.sendToDisplay());
}
test "trace evidence validation encode decode and every allocation failure" {
    try roundtrip(t.allocator);
    try t.checkAllAllocationFailures(t.allocator, roundtrip, .{});
    var record = validRecord();
    record.invalid_reason = "missing_scheduled";
    const forged = try record.encode(t.allocator);
    defer t.allocator.free(forged);
    try t.expectError(error.InconsistentValidation, s.interaction_record.decode(t.allocator, forged));
    record.invalid_reason = "capture_cancelled";
    const external = try record.encode(t.allocator);
    defer t.allocator.free(external);
    const decoded = try s.interaction_record.decode(t.allocator, external);
    defer decoded.deinit();
    try t.expect(!decoded.value.valid);
    record.invalid_reason = null;
    record.motion_ack_ns = 10;
    try t.expectEqualStrings("non_monotonic_timestamps", record.failure(null).?);
    record.motion_ack_ns = null;
    record.token = "0123456789ABCDEF";
    try t.expectEqualStrings("invalid_token", record.failure(null).?);
    record.token = "\xff";
    try t.expectError(error.InvalidUTF8, record.encode(t.allocator));
    var large: [65536]u8 = @splat('x');
    record = validRecord();
    record.pair_id = &large;
    try t.expectError(error.RecordTooLarge, record.encode(t.allocator));
    try t.expectError(error.MissingField, s.interaction_record.decode(t.allocator, "{}"));
}
fn paint(pixels: []u8, stride: usize, x: usize, y: usize, payload: s.interaction_marker.Payload) void {
    const bits: u176 = (@as(u176, 0xa5c3) << 160) | (@as(u176, payload.token) << 96) | (@as(u176, payload.revision) << 32) | payload.checksum;
    for (0..176) |i| {
        const component: u8 = if (bits & (@as(u176, 1) << @intCast(175 - i)) != 0) 8 else 247;
        const offset = (y + (i / 88) * 4 + 2) * stride + (x + (i % 88) * 4 + 2) * 4;
        @memset(pixels[offset..][0..3], component);
    }
}
test "marker ROI exact threshold padded stride truncation ambiguity and overflow" {
    const width = 400;
    const height = 48;
    const stride = 1648;
    const pixels = try t.allocator.alloc(u8, stride * height);
    defer t.allocator.free(pixels);
    @memset(pixels, 0x7f);
    const payload: s.interaction_marker.Payload = .{ .token = 0x0123456789abcdef, .revision = 789, .checksum = 0xaabbccdd };
    paint(pixels, stride, 8, 8, payload);
    const exact = s.interaction_marker.detect(pixels, width, height, stride, "0123456789abcdef", payload.checksum);
    try t.expectEqual(payload, exact.exact);
    try t.expectEqual(.none, s.interaction_marker.detect(pixels[0..100], width, height, stride, "0123456789abcdef", payload.checksum));
    try t.expectEqual(.none, s.interaction_marker.detect(pixels, std.math.maxInt(usize), height, stride, "0123456789abcdef", payload.checksum));
    try t.expectEqual(.none, s.interaction_marker.detect(pixels, width, height, std.math.maxInt(usize), "0123456789abcdef", payload.checksum));
    try t.expectEqual(.none, s.interaction_marker.detect(pixels, width, height, stride, "0123456789ABCDEF", payload.checksum));
    paint(pixels, stride, 8, 20, payload);
    try t.expectEqual(@as(usize, 2), s.interaction_marker.detect(pixels, width, height, stride, "0123456789abcdef", payload.checksum).ambiguous);
    pixels[10 * stride + 10 * 4] = 9;
    try t.expectEqual(payload, s.interaction_marker.detect(pixels, width, height, stride, "0123456789abcdef", payload.checksum).exact);
}

const trace = s.interaction_trace;
const config: trace.Config = .{ .pair_id = "pair", .version = "zig", .run_id = "run", .order = 1, .action = .click, .token = "0123456789abcdef", .checksum = 0xaabbccdd };
fn identity(revision: u64) trace.Identity {
    return .{ .desktop_generation = 1, .channel = 0, .surface = 0, .surface_generation = 1, .revision = revision, .sequence = revision };
}
fn seeded(allocator: std.mem.Allocator) !*trace.Assembler {
    const value = try trace.Assembler.create(allocator, config);
    value.hostInput(1, 2, 3);
    value.sendCompleted(100, null);
    value.guestEvidence(9000, 9010, 9);
    return value;
}
fn observe(value: *trace.Assembler, revision: u64, marked: bool) void {
    value.observe(identity(revision), 4, 5, if (marked) .{ .exact = .{ .token = 0x0123456789abcdef, .revision = 9, .checksum = 0xaabbccdd } } else .none);
}
fn finish(value: *trace.Assembler, allocator: std.mem.Allocator) !std.json.Parsed(s.interaction_record.Record) {
    const bytes = try value.finishEncoded(allocator, null);
    defer allocator.free(bytes);
    return s.interaction_record.decode(allocator, bytes);
}
test "trace authoritative dropped redraw retries and unrelated completions do not consume target" {
    const value = try seeded(t.allocator);
    defer value.destroy();
    observe(value, 1, false);
    value.select(identity(1), 6, 7);
    value.commit(identity(1), 8);
    try t.expect(!value.presented(identity(1), 9));
    value.select(identity(1), 6, 7);
    value.commit(identity(1), 8);
    observe(value, 2, true);
    value.select(identity(2), 6, 7);
    value.commit(identity(2), 8);
    try t.expect(!value.presented(identity(1), 9));
    value.drop(identity(2));
    value.select(identity(2), 6, 7);
    value.commit(identity(2), 8);
    try t.expect(value.presented(identity(2), 9));
    for (3..40) |n| observe(value, n, false);
    const result = try finish(value, t.allocator);
    defer result.deinit();
    try t.expect(result.value.valid);
    try t.expectEqual(@as(?u64, 2), result.value.frame_revision);
}
test "trace marker replacement recovers only with a later independently observed marker delivery" {
    const value = try seeded(t.allocator);
    defer value.destroy();
    observe(value, 1, true);
    value.select(identity(1), 6, 7);
    value.commit(identity(1), 8);
    observe(value, 2, false);
    value.select(identity(2), 6, 7);
    value.commit(identity(2), 8);
    const replaced = try finish(value, t.allocator);
    defer replaced.deinit();
    try t.expectEqualStrings("marker_replaced_before_presented", replaced.value.invalid_reason.?);
    observe(value, 3, true);
    value.select(identity(3), 6, 7);
    value.commit(identity(3), 8);
    try t.expect(value.presented(identity(3), 9));
    const recovered = try finish(value, t.allocator);
    defer recovered.deinit();
    try t.expect(recovered.value.valid);
}
test "trace retirement budget duplicate stages and late frames retain first failure" {
    const value = try seeded(t.allocator);
    defer value.destroy();
    observe(value, 1, true);
    value.select(identity(1), 6, 7);
    try value.retireSurface(.{ .channel = 0, .surface = 0 }, 1);
    value.commit(identity(1), 8);
    try t.expect(!value.presented(identity(1), 9));
    observe(value, 1, true);
    value.hostInput(1, 2, 3);
    const result = try finish(value, t.allocator);
    defer result.deinit();
    try t.expectEqualStrings("surface_lifecycle_retired", result.value.invalid_reason.?);
    const capped = try seeded(t.allocator);
    defer capped.destroy();
    for (1..18) |n| observe(capped, n, true);
    const limited = try finish(capped, t.allocator);
    defer limited.deinit();
    try t.expectEqualStrings("too_many_observed_frames", limited.value.invalid_reason.?);
    const repeated = try seeded(t.allocator);
    defer repeated.destroy();
    observe(repeated, 1, true);
    repeated.select(identity(1), 6, 7);
    repeated.commit(identity(1), 8);
    repeated.select(identity(1), 6, 7);
    const duplicate = try finish(repeated, t.allocator);
    defer duplicate.deinit();
    try t.expectEqualStrings("duplicate_selection_after_commit", duplicate.value.invalid_reason.?);
}
fn traceAllocations(allocator: std.mem.Allocator) !void {
    const value = try seeded(allocator);
    defer value.destroy();
    observe(value, 1, true);
    try value.retireSurface(.{ .channel = 1, .surface = 1 }, 1);
    value.select(identity(1), 6, 7);
    value.commit(identity(1), 8);
    _ = value.presented(identity(1), 9);
    const result = try finish(value, allocator);
    defer result.deinit();
    try t.expect(result.value.valid);
}
test "trace owns configuration and unwinds every allocation failure" {
    try t.checkAllAllocationFailures(t.allocator, traceAllocations, .{});
}

extern "c" fn mkdtemp([*:0]u8) ?[*:0]u8;
const Fixture = struct {
    path: [64:0]u8 = @splat(0),
    root: struct { fd: std.c.fd_t },
    fn init() !Fixture {
        var path: [64:0]u8 = @splat(0);
        const template = "/tmp/spicezig-diagnostics-XXXXXX";
        @memcpy(path[0..template.len], template);
        const name = mkdtemp(&path) orelse return error.CreateFailed;
        errdefer _ = std.c.rmdir(name);
        const fd = std.c.open(name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
        if (fd < 0) return error.OpenFailed;
        return .{ .path = path, .root = .{ .fd = fd } };
    }
    fn deinit(self: *Fixture) void {
        for ([_][*:0]const u8{ "file", "sub/file", ".file.lock", "sub/.file.lock", "held" }) |name| _ = std.c.unlinkat(self.root.fd, name, 0);
        _ = std.c.unlinkat(self.root.fd, "sub", std.c.AT.REMOVEDIR);
        _ = std.c.close(self.root.fd);
        _ = std.c.rmdir(&self.path);
    }
    fn file(self: *Fixture, name: [*:0]const u8, bytes: []const u8) !void {
        const fd = std.c.openat(self.root.fd, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(c_uint, 0o600));
        if (fd < 0) return error.CreateFailed;
        defer _ = std.c.close(fd);
        try t.expectEqual(@as(isize, @intCast(bytes.len)), std.c.write(fd, bytes.ptr, bytes.len));
    }
};
fn outputPath(f: *Fixture, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(t.allocator, "{s}/{s}", .{ std.mem.span(@as([*:0]const u8, &f.path)), name });
}
test "trace writer canonical atomic mode0600 exact retries and symlink rejection" {
    var f = try Fixture.init();
    defer f.deinit();
    defer _ = std.c.unlinkat(f.root.fd, ".file.lock", 0);
    const path = try outputPath(&f, "file");
    defer t.allocator.free(path);
    const writer = try s.interaction_writer.Writer.init(t.allocator, path);
    defer writer.deinit();
    const encoded = try validRecord().encode(t.allocator);
    defer t.allocator.free(encoded);
    try writer.append(encoded);
    try writer.append(encoded);
    var stat: std.c.Stat = undefined;
    try t.expectEqual(0, std.c.fstatat(f.root.fd, "file", &stat, 0));
    try t.expectEqual(@as(i64, @intCast(encoded.len + 1)), stat.size);
    try t.expectEqual(@as(u16, 0o600), stat.mode & 0o777);
    try t.expectEqual(0, std.c.unlinkat(f.root.fd, "file", 0));
    try f.file("file", "{}\n");
    try t.expectError(error.InvalidExistingJSONL, writer.append(encoded));
    try t.expectEqual(0, std.c.unlinkat(f.root.fd, "file", 0));
    try f.file("held", "private");
    defer _ = std.c.unlinkat(f.root.fd, "held", 0);
    try t.expectEqual(0, std.c.symlinkat("held", f.root.fd, "file"));
    try t.expectError(error.OutputIsSymbolicLink, writer.append(encoded));
    try t.expectEqual(0, std.c.unlinkat(f.root.fd, "file", 0));
    try t.expectEqual(0, std.c.unlinkat(f.root.fd, ".file.lock", 0));
    try t.expectEqual(0, std.c.symlinkat("held", f.root.fd, ".file.lock"));
    try t.expectError(error.OutputIsSymbolicLink, writer.append(encoded));
}
test "capture freezes evidence on write failure then retries once after directory becomes available" {
    var f = try Fixture.init();
    defer f.deinit();
    defer _ = std.c.unlinkat(f.root.fd, "sub/.file.lock", 0);
    const path = try outputPath(&f, "sub/file");
    defer t.allocator.free(path);
    const registry = try s.interaction_capture.Registry.create(t.allocator);
    defer registry.release();
    const capture = try s.interaction_capture.Capture.create(t.allocator, registry, config, path);
    defer capture.destroy();
    try t.expectError(error.CaptureAlreadyActive, s.interaction_capture.Capture.create(t.allocator, registry, config, path));
    try capture.hostInput(1, 2, 3);
    try capture.sendCompleted(100, null);
    try capture.guestEvidence(9000, 9010, 9);
    // Assembler observations here are metadata fixtures; native/CPU integration
    // exercises the actual frame mapping separately.
    observe(capture.assembler, 1, true);
    registry.selected(identity(1), 6, 7);
    registry.committed(identity(1), 8);
    registry.presented(identity(1), 9);
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try t.expectEqual(identity(1), try capture.waitPresented(&token));
    try t.expectError(error.OutputDirectoryUnavailable, capture.finish(t.allocator, null));
    try t.expectError(error.CaptureAlreadyFinished, capture.hostInput(1, 2, 3));
    // Old callbacks no longer reach the detached assembler.
    registry.selected(identity(1), 20, 30);
    registry.presented(identity(1), 100);
    try t.expectEqual(0, std.c.mkdirat(f.root.fd, "sub", 0o700));
    const result = try capture.finish(t.allocator, "ignored_on_retry");
    defer t.allocator.free(result);
    const parsed = try s.interaction_record.decode(t.allocator, result);
    defer parsed.deinit();
    try t.expect(parsed.value.valid);
    try t.expectEqual(@as(?u64, 9), parsed.value.presented_ns);
    try t.expectError(error.CaptureAlreadyFinished, capture.finish(t.allocator, null));
    const next = try s.interaction_capture.Capture.create(t.allocator, registry, config, path);
    next.destroy();
}
const WaitTask = struct {
    waiter: *s.interaction_waiter.Waiter,
    token: *s.cancel.Token,
    result: ?trace.Identity = null,
    failure: ?anyerror = null,
    fn run(self: *WaitTask) void {
        self.result = self.waiter.wait(self.token) catch |err| {
            self.failure = err;
            return;
        };
    }
};
test "presentation waiter completion cancellation finish and reuse" {
    var waiter: s.interaction_waiter.Waiter = .{};
    defer waiter.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var task: WaitTask = .{ .waiter = &waiter, .token = &token };
    const thread = try std.Thread.spawn(.{}, WaitTask.run, .{&task});
    token.cancel();
    thread.join();
    try t.expectEqual(error.Cancelled, task.failure.?);
    var fresh: s.cancel.Token = .{};
    defer fresh.deinit();
    var completed: WaitTask = .{ .waiter = &waiter, .token = &fresh };
    const other = try std.Thread.spawn(.{}, WaitTask.run, .{&completed});
    waiter.complete(identity(7));
    other.join();
    try t.expectEqual(identity(7), completed.result.?);
    waiter.finish();
    try t.expectEqual(identity(7), try waiter.wait(&token));
    var ended: s.interaction_waiter.Waiter = .{};
    defer ended.deinit();
    ended.finish();
    try t.expectError(error.CaptureAlreadyFinished, ended.wait(&fresh));
}
fn captureAllocations(allocator: std.mem.Allocator, path: []const u8) !void {
    const registry = try s.interaction_capture.Registry.create(allocator);
    defer registry.release();
    const capture = try s.interaction_capture.Capture.create(allocator, registry, config, path);
    defer capture.destroy();
    const result = try capture.finish(allocator, "cancelled");
    defer allocator.free(result);
    const parsed = try s.interaction_record.decode(allocator, result);
    defer parsed.deinit();
    try t.expectEqualStrings("cancelled", parsed.value.invalid_reason.?);
}
test "capture writer and frozen record unwind all allocator failures" {
    var f = try Fixture.init();
    defer f.deinit();
    defer _ = std.c.unlinkat(f.root.fd, ".file.lock", 0);
    const path = try outputPath(&f, "file");
    defer t.allocator.free(path);
    try t.checkAllAllocationFailures(t.allocator, captureAllocations, .{path});
}
