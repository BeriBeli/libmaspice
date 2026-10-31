const std = @import("std");
const t = std.testing;
const s = @import("spice");
const a = t.allocator;
extern "c" fn usleep(useconds: u32) c_int;
fn waitFor(context: anytype, comptime ready: fn (@TypeOf(context)) bool) !void {
    for (0..3000) |_| {
        if (ready(context)) return;
        _ = usleep(1000);
    }
    return error.WaitDidNotStart;
}
const GLZJob = struct {
    decoder: *s.glz.Decoder,
    token: s.cancel.Token = .{},
    payload: []const u8,
    result: ?s.image.Image = null,
    failure: ?anyerror = null,
    fn run(self: *GLZJob) void {
        self.result = self.decoder.decode(self.payload, 2, 1, 0, &self.token) catch |err| {
            self.failure = err;
            return;
        };
    }
    fn deinit(self: *GLZJob) void {
        if (self.result) |image| image.release();
        self.token.deinit();
    }
};
const literal = [_]u8{ 0x20, 0x20, 0x5a, 0x4c, 0, 1, 0, 1, 24, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 3, 4, 5, 6 };
const reference = [_]u8{ 0x20, 0x20, 0x5a, 0x4c, 0, 1, 0, 1, 24, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0x40, 0, 1 };
fn waitingGLZ(decoder: *s.glz.Decoder) bool {
    return decoder.diagnostics().waits == 1;
}
test "GLZ future dependency wakes with retained pixels; reset and cancellation drain reservations" {
    for (0..3) |scenario| {
        var pool: s.codec_executor.Executor = .{};
        defer pool.deinit();
        var decoder = s.glz.Decoder.init(a, &pool, .{});
        defer decoder.deinit();
        var job: GLZJob = .{ .decoder = &decoder, .payload = &reference };
        defer job.deinit();
        var joined = false;
        const thread = try std.Thread.spawn(.{}, GLZJob.run, .{&job});
        defer {
            job.token.cancel();
            if (!joined) thread.join();
        }
        try waitFor(&decoder, waitingGLZ);
        if (scenario == 0) {
            var token: s.cancel.Token = .{};
            defer token.deinit();
            const image = try decoder.decode(&literal, 2, 1, 0, &token);
            image.release();
        } else if (scenario == 1) try decoder.clear() else job.token.cancel();
        thread.join();
        joined = true;
        if (scenario == 0) {
            try t.expect(job.failure == null);
            try t.expectEqualSlices(u8, &.{ 1, 2, 3, 0, 4, 5, 6, 0 }, job.result.?.pixels());
        } else try t.expectEqual(error.Cancelled, job.failure.?);
        try t.expectEqual(@as(usize, 0), decoder.diagnostics().reservations);
        try t.expectEqual(@as(usize, 0), decoder.diagnostics().wait_bytes);
    }
}
const CacheJob = struct {
    cache: *s.image_cache.Cache,
    token: s.cancel.Token = .{},
    kind: enum { replace, lookup },
    result: ?s.image.Image = null,
    mutation: ?s.image_cache.Mutation = null,
    failure: ?anyerror = null,
    fn run(self: *CacheJob) void {
        switch (self.kind) {
            .replace => self.mutation = self.cache.begin(1, false, .replace, 1, &self.token) catch |err| {
                self.failure = err;
                return;
            },
            .lookup => self.result = self.cache.resolve(1, .lossless, 1, &self.token) catch |err| {
                self.failure = err;
                return;
            },
        }
    }
    fn deinit(self: *CacheJob) void {
        if (self.result) |image| image.release();
        if (self.mutation) |m| self.cache.abort(m);
        self.token.deinit();
    }
};
fn queuedCache(cache: *s.image_cache.Cache) bool {
    return cache.diagnostics().queued == 1;
}
fn waitingCache(cache: *s.image_cache.Cache) bool {
    return cache.diagnostics().waiters == 1;
}
test "cache queues replacement before decode and lossless lookup waits for successful Surface commit" {
    var cache = try s.image_cache.Cache.init(a, .{});
    defer cache.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const image = try s.image.Image.create(a, 1, 1, true, .opaque_pixels);
    defer image.release();
    @memset(image.unpublishedPixels(), 7);
    const first = try cache.begin(1, true, .cache, 1, &token);
    defer cache.abort(first);
    var replacement: CacheJob = .{ .cache = &cache, .kind = .replace };
    defer replacement.deinit();
    var join_replacement = true;
    const replace_thread = try std.Thread.spawn(.{}, CacheJob.run, .{&replacement});
    defer {
        replacement.token.cancel();
        if (join_replacement) replace_thread.join();
    }
    try waitFor(&cache, queuedCache);
    _ = try cache.stage(first, image);
    try t.expectEqual(.committed, cache.commit(first));
    replace_thread.join();
    join_replacement = false;
    try t.expect(replacement.failure == null);
    var lookup: CacheJob = .{ .cache = &cache, .kind = .lookup };
    defer lookup.deinit();
    var join_lookup = true;
    const lookup_thread = try std.Thread.spawn(.{}, CacheJob.run, .{&lookup});
    defer {
        lookup.token.cancel();
        if (join_lookup) lookup_thread.join();
    }
    try waitFor(&cache, waitingCache);
    const mutation = replacement.mutation.?;
    _ = try cache.stage(mutation, image);
    try t.expectEqual(.committed, cache.commit(mutation));
    replacement.mutation = null;
    lookup_thread.join();
    join_lookup = false;
    try t.expect(lookup.failure == null);
    try t.expectEqual(@as(u8, 7), lookup.result.?.pixels()[0]);
}
test "cache clear and close wake queued mutation and image wait with no retained budget" {
    for (0..3) |scenario| {
        var cache = try s.image_cache.Cache.init(a, .{});
        defer cache.deinit();
        var token: s.cancel.Token = .{};
        defer token.deinit();
        const first = try cache.begin(1, false, .cache, 1, &token);
        defer cache.abort(first);
        var job: CacheJob = .{ .cache = &cache, .kind = if (scenario == 2) .lookup else .replace };
        defer job.deinit();
        var joined = false;
        const thread = try std.Thread.spawn(.{}, CacheJob.run, .{&job});
        defer {
            job.token.cancel();
            if (!joined) thread.join();
        }
        if (scenario == 2) try waitFor(&cache, waitingCache) else try waitFor(&cache, queuedCache);
        if (scenario == 0) cache.clear() else if (scenario == 1) cache.close() else job.token.cancel();
        thread.join();
        joined = true;
        try t.expect(job.failure != null);
        try t.expectEqual(@as(usize, 0), cache.diagnostics().queued);
        try t.expectEqual(@as(usize, 0), cache.diagnostics().wait_bytes);
    }
}
