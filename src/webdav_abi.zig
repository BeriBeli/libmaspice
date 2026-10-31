//! Native WebDAV host owner. Explicit application-selected root only; defaults
//! are read-only. The event consumer controls attachment and observation order.
const std = @import("std");
const s = @import("root.zig");
const a = std.heap.c_allocator;
const Desktop = s.supervisor.Supervisor(s.desktop_child);
pub const Runner = s.webdav_runner.Runner(Desktop, s.webdav_fs.Filesystem);
pub const Server = @import("webdav_server.zig").Server;
const Responses = @import("webdav_server.zig").Responses;
pub const Handle = struct { server: *Server, runner: *Runner };
pub const Options = extern struct { channel_id: u8, read_write: u8, reserved: [6]u8, filesystem_parallelism: usize, maximum_clients: usize, maximum_jobs: usize, maximum_retained_bytes: usize, maximum_header_bytes: usize, maximum_body_bytes: usize };
pub const Diagnostics = extern struct { clients: u64, buffered_bytes: u64, pending_jobs: u64, pending_bytes: u64, reserved_bytes: u64, peak_jobs: u64, peak_bytes: u64, completed: u64, cancelled: u64, rejected: u64, discarded: u64 };
pub fn status(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => -2,
        error.Closed, error.Cancelled => -31,
        error.StaleWebDAVGeneration => -50,
        error.InvalidLimits => -51,
        error.InvalidRequest, error.HeaderTooLarge, error.BodyTooLarge => -52,
        error.TooManyClients, error.TooManyPendingJobs, error.RetainedBytesExceeded => -53,
        else => -1,
    };
}
pub export fn spice_zig_webdav_options(output: ?*Options) void {
    if (output) |out| out.* = .{ .channel_id = 0, .read_write = 0, .reserved = @splat(0), .filesystem_parallelism = 2, .maximum_clients = 64, .maximum_jobs = 64, .maximum_retained_bytes = 256 * 1024 * 1024, .maximum_header_bytes = 64 * 1024, .maximum_body_bytes = 64 * 1024 * 1024 };
}
pub export fn spice_zig_webdav_create(desktop: ?*Desktop, root_path: ?[*]const u8, root_size: usize, options: ?*const Options, output: ?*?*Handle) c_int {
    const out = output orelse return -1;
    out.* = null;
    const runtime = desktop orelse return -1;
    const path = root_path orelse return -1;
    const opts = options orelse return -1;
    if (opts.read_write > 1 or !std.mem.allEqual(u8, &opts.reserved, 0) or root_size == 0 or root_size > 65536) return -1;
    const server = Server.create(a, path[0..root_size], opts.read_write != 0, nativeOptions(opts.*)) catch |err| return status(err);
    defer server.release();
    return spice_zig_webdav_create_shared(runtime, opts.channel_id, server, out);
}
fn nativeOptions(opts: Options) s.webdav_runner.Options {
    return .{ .channel_id = opts.channel_id, .filesystem_parallelism = opts.filesystem_parallelism, .limits = .{ .clients = opts.maximum_clients, .jobs = opts.maximum_jobs, .retained_bytes = opts.maximum_retained_bytes, .http = .{ .header_bytes = opts.maximum_header_bytes, .body_bytes = opts.maximum_body_bytes } } };
}
pub export fn spice_zig_webdav_create_shared(desktop: ?*Desktop, channel: u8, server: ?*Server, output: ?*?*Handle) c_int {
    const out = output orelse return -1;
    out.* = null;
    const runtime = desktop orelse return -1;
    const shared = server orelse return -1;
    const self = a.create(Handle) catch return -2;
    self.* = .{ .server = shared, .runner = Runner.createShared(a, runtime, &shared.filesystem, channel, &shared.shared) catch |err| {
        a.destroy(self);
        return status(err);
    } };
    shared.retain();
    out.* = self;
    return 0;
}

pub export fn spice_zig_webdav_observe(handle: ?*Handle, event: ?*const Desktop.Event) c_int {
    const self = handle orelse return -1;
    const value = event orelse return -1;
    self.runner.observe(value.*) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_webdav_stop(handle: ?*Handle) void {
    if (handle) |self| self.runner.stop();
}
pub export fn spice_zig_webdav_destroy(handle: ?*Handle) void {
    if (handle) |self| {
        self.runner.destroy();
        self.server.release();
        a.destroy(self);
    }
}
pub export fn spice_zig_webdav_status(handle: ?*Handle, error_category: ?*?[*:0]const u8) c_int {
    if (error_category) |out| out.* = null;
    const self = handle orelse return -1;
    const value = self.runner.status();
    if (value.failure) |err| {
        if (error_category) |out| out.* = @errorName(err).ptr;
        return status(err);
    }
    return @intFromBool(value.finished);
}
pub export fn spice_zig_webdav_diagnostics(handle: ?*Handle, output: ?*Diagnostics) c_int {
    const self = handle orelse return -1;
    const out = output orelse return -1;
    const v = self.runner.diagnostics();
    out.* = .{ .clients = v.clients, .buffered_bytes = v.buffered_bytes, .pending_jobs = v.pending_jobs, .pending_bytes = v.pending_bytes, .reserved_bytes = v.reserved_bytes, .peak_jobs = v.peak_jobs, .peak_bytes = v.peak_bytes, .completed = v.completed, .cancelled = v.cancelled, .rejected = v.rejected, .discarded = v.discarded };
    return 0;
}

fn serverStatus(err: anyerror) c_int {
    return switch (err) {
        error.HeaderTooLarge => -55,
        error.BodyTooLarge, error.RetainedBytesExceeded => -56,
        error.TooManyClients => -57,
        error.PathEscapesRoot => -58,
        else => status(err),
    };
}
pub export fn spice_zig_webdav_server_create(root: ?[*]const u8, size: usize, options: ?*const Options, output: ?*?*Server) c_int {
    const out = output orelse return -1;
    out.* = null;
    const path = root orelse return -1;
    const opts = options orelse return -1;
    if (opts.read_write > 1 or !std.mem.allEqual(u8, &opts.reserved, 0) or size == 0 or size > 65536) return -1;
    out.* = Server.create(a, path[0..size], opts.read_write != 0, nativeOptions(opts.*)) catch |err| return serverStatus(err);
    return 0;
}
pub export fn spice_zig_webdav_server_destroy(server: ?*Server) void {
    if (server) |self| self.release();
}
pub export fn spice_zig_webdav_server_receive(server: ?*Server, client: i64, bytes: ?[*]const u8, size: usize, output: ?*?*Responses) c_int {
    const out = output orelse return -1;
    out.* = null;
    const self = server orelse return -1;
    if (size > self.shared.queue.limits.retained_bytes) return -56;
    if (size != 0 and bytes == null) return -52;
    const responses = a.create(Responses) catch return -2;
    responses.* = self.receive(client, if (bytes) |data| data[0..size] else &.{}) catch |err| {
        a.destroy(responses);
        return serverStatus(err);
    };
    out.* = responses;
    return 0;
}
pub export fn spice_zig_webdav_server_close(server: ?*Server, client: i64, all: u8) void {
    if (server) |self| self.close(if (all == 0) client else null);
}
pub export fn spice_zig_webdav_responses_count(responses: ?*const Responses) usize {
    return if (responses) |value| value.items.items.len else 0;
}
pub export fn spice_zig_webdav_responses_bytes(responses: ?*const Responses, index: usize, size: ?*usize) ?[*]const u8 {
    const out = size orelse return null;
    out.* = 0;
    const value = responses orelse return null;
    if (index >= value.items.items.len) return null;
    const bytes = value.items.items[index];
    out.* = bytes.len;
    return bytes.ptr;
}
pub export fn spice_zig_webdav_responses_destroy(responses: ?*Responses) void {
    if (responses) |value| {
        value.deinit();
        a.destroy(value);
    }
}
