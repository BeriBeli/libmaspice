//! One server's filesystem and admission state, shared by standalone calls and
//! session attachments. Reference owners outlive every joined runner. The legacy
//! mutex serializes compatibility calls without blocking native event admission.
const std = @import("std");
const sync = @import("sync.zig");
const fs = @import("webdav_fs.zig");
const executor = @import("webdav_runner.zig");
pub const Responses = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]u8) = .empty,
    pub fn deinit(self: *Responses) void {
        for (self.items.items) |bytes| self.allocator.free(bytes);
        self.items.deinit(self.allocator);
    }
};
pub const Server = struct {
    allocator: std.mem.Allocator,
    references: std.atomic.Value(usize) = .init(1),
    filesystem: fs.Filesystem,
    shared: executor.Shared,
    legacy_mutex: sync.Mutex = .{},
    pub fn create(a: std.mem.Allocator, path: []const u8, read_write: bool, options: executor.Options) !*Server {
        const self = try a.create(Server);
        errdefer a.destroy(self);
        const filesystem = try fs.Filesystem.open(a, path, read_write, options.limits.http.body_bytes);
        errdefer filesystem.deinit();
        self.* = .{ .allocator = a, .filesystem = filesystem, .shared = try executor.Shared.init(a, options) };
        return self;
    }
    pub fn retain(self: *Server) void {
        const previous = self.references.fetchAdd(1, .monotonic);
        std.debug.assert(previous != 0 and previous != std.math.maxInt(usize));
    }
    pub fn release(self: *Server) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        self.shared.deinit();
        self.filesystem.deinit();
        self.legacy_mutex.deinit();
        self.allocator.destroy(self);
    }
    pub fn receive(self: *Server, client: i64, bytes: []const u8) !Responses {
        self.legacy_mutex.lock();
        defer self.legacy_mutex.unlock();
        var responses: Responses = .{ .allocator = self.allocator };
        errdefer responses.deinit();
        if (bytes.len == 0) {
            self.shared.close(client);
            return responses;
        }
        try self.shared.queue.beginLegacy(client, bytes);
        defer self.shared.queue.endLegacy(client);
        while (try self.shared.queue.nextLegacy(client)) |request| {
            defer request.deinit();
            const response = try self.filesystem.execute(request);
            errdefer self.allocator.free(response);
            try responses.items.append(self.allocator, response);
        }
        return responses;
    }
    pub fn close(self: *Server, client: ?i64) void {
        self.legacy_mutex.lock();
        defer self.legacy_mutex.unlock();
        self.shared.close(client);
    }
};
