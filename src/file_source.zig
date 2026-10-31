//! Immutable descriptor ownership for bounded file-transfer reads. Tickets retain
//! the source so cancellation/removal cannot close a descriptor during pread.
//! Only regular files are accepted; no writes or directory traversal occur here.
const std = @import("std");
const wire = @import("bytes.zig");
const cancel = @import("cancel.zig");
pub const Source = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    fd: std.c.fd_t,
    size: u64,
    pub fn open(a: std.mem.Allocator, path: []const u8) !*Source {
        if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidFilePath;
        const terminated = try a.dupeSentinel(u8, path, 0);
        defer a.free(terminated);
        // NONBLOCK prevents special files from hanging before fstat rejects them.
        const fd = std.c.open(terminated, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true });
        if (fd < 0) return error.FileOpenFailed;
        return adopt(a, fd);
    }
    /// Consumes fd even on failure. External callers must not close it again.
    pub fn adopt(a: std.mem.Allocator, fd: std.c.fd_t) !*Source {
        errdefer _ = std.c.close(fd);
        var stat: std.c.Stat = undefined;
        if (std.c.fstat(fd, &stat) != 0) return error.FileStatFailed;
        if (stat.mode & std.c.S.IFMT != std.c.S.IFREG or stat.size < 0) return error.NotRegularFile;
        const self = try a.create(Source);
        self.* = .{ .allocator = a, .fd = fd, .size = @intCast(stat.size) };
        return self;
    }
    pub fn retain(self: *Source) *Source {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old > 0 and old < std.math.maxInt(usize));
        return self;
    }
    pub fn release(self: *Source) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            _ = std.c.close(self.fd);
            self.allocator.destroy(self);
        }
    }
    pub fn read(self: *Source, a: std.mem.Allocator, offset: u64, count: usize, token: *cancel.Token) !wire.Slice {
        if (count > 16000 or offset > self.size or count > self.size - offset or offset > std.math.maxInt(i64)) return error.InvalidFileRange;
        try token.check();
        const result = try wire.Slice.allocate(a, count);
        errdefer result.release();
        var read_bytes: usize = 0;
        while (read_bytes < count) {
            try token.check();
            const read_count = std.c.pread(self.fd, result.storage.bytes[read_bytes..].ptr, count - read_bytes, @intCast(offset + read_bytes));
            if (read_count < 0) {
                if (std.c.errno(read_count) == .INTR) continue;
                return error.FileReadFailed;
            }
            if (read_count == 0) return error.FileTruncated;
            read_bytes += @intCast(read_count);
        }
        try token.check();
        return result;
    }
};
