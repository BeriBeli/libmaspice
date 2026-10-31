//! Bounded four-way child connection preparation. Every failure cancels the
//! entire unpublished group and joins all attempts, including late successes.
const std = @import("std");
const network = @import("session.zig");
const endpoint = @import("endpoint.zig");
const barrier = @import("barrier.zig");
const sync = @import("sync.zig");
pub const Video = enum { mjpeg, h264, h265 };
pub fn capabilities(key: barrier.Key, video: Video, migration_seamless: ?bool) u32 {
    return switch (key.kind) {
        1 => @as(u32, 1 << 0 | 1 << 2) | if (migration_seamless orelse true) @as(u32, 1 << 3) else 0,
        2 => @as(u32, 1 << 0 | 1 << 1 | 1 << 4 | 1 << 8 | 1 << 9) | switch (video) {
            .mjpeg => @as(u32, 0),
            .h264 => @as(u32, 1 << 11),
            .h265 => @as(u32, 1 << 14),
        },
        5 => 1 << 1 | 1 << 2,
        else => 0,
    };
}
pub fn connectOne(group: *network.Session, config: endpoint.Config, key: barrier.Key, connection_id: u32, password: []const u8, video: Video, migration_seamless: ?bool) !*network.Connection {
    const words = [_]u32{capabilities(key, video, migration_seamless)};
    return group.connect(config.host, config.port, config.tls, config.timeout_ms, .{ .connection_id = connection_id, .channel_type = key.kind, .channel_id = key.id, .common = &.{11}, .channel = if (words[0] == 0) &.{} else &words }, password);
}
pub fn validate(allocator: std.mem.Allocator, keys: []const barrier.Key, main_key: barrier.Key, maximum: usize) ![]barrier.Key {
    if (keys.len > 65536) return error.TooManyChannels;
    var seen: std.StaticBitSet(65536) = .empty;
    var count: usize = 0;
    for (keys) |key| {
        if (seen.isSet(key.index())) return error.DuplicateChannel;
        seen.set(key.index());
        if (key.index() != main_key.index()) count += 1;
    }
    if (count >= maximum) return error.TooManyChannels;
    const output = try allocator.alloc(barrier.Key, count);
    var index: usize = 0;
    for (keys) |key| {
        if (key.index() == main_key.index()) continue;
        output[index] = key;
        index += 1;
    }
    return output;
}
const Work = struct {
    group: *network.Session,
    config: endpoint.Config,
    password: []const u8,
    keys: []const barrier.Key,
    connection_id: u32,
    video: Video,
    output: []*network.Connection,
    mutex: sync.Mutex = .{},
    next: usize = 0,
    failure: ?anyerror = null,
    fn run(self: *Work) void {
        while (true) {
            self.mutex.lock();
            if (self.failure != null or self.next == self.keys.len) {
                self.mutex.unlock();
                return;
            }
            const index = self.next;
            self.next += 1;
            self.mutex.unlock();
            const connection = connectOne(self.group, self.config, self.keys[index], self.connection_id, self.password, self.video, null) catch |err| {
                self.mutex.lock();
                if (self.failure == null) self.failure = err;
                self.mutex.unlock();
                self.group.cancel();
                return;
            };
            self.output[index] = connection;
        }
    }
};
pub fn connect(group: *network.Session, config: endpoint.Config, keys: []const barrier.Key, connection_id: u32, password: []const u8, video: Video) ![]*network.Connection {
    const requests = try validate(group.allocator, keys, .{ .kind = 1, .id = 0 }, group.maximum_channels);
    defer group.allocator.free(requests);
    const output = try group.allocator.alloc(*network.Connection, requests.len);
    errdefer group.allocator.free(output);
    var work: Work = .{ .group = group, .config = config, .password = password, .keys = requests, .connection_id = connection_id, .video = video, .output = output };
    defer work.mutex.deinit();
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    errdefer {
        group.cancel();
        for (threads[0..started]) |thread| thread.join();
    }
    for (0..@min(4, requests.len)) |index| {
        threads[index] = try std.Thread.spawn(.{}, Work.run, .{&work});
        started += 1;
    }
    for (threads[0..started]) |thread| thread.join();
    started = 0;
    if (work.failure) |failure| return failure;
    if (group.isCancelled()) return error.Cancelled;
    return output;
}
