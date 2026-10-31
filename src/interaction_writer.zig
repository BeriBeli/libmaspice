//! Explicit opt-in, bounded canonical JSONL output. Cooperates with existing
//! Swift writers via the same .basename.lock POSIX record lock. A process mutex
//! also serializes Zig writers (POSIX locks alone do not serialize threads).
//! A complete mode-0600 inode is fsynced before atomic rename. Retrying an exact
//! existing line only fsyncs the directory, covering an uncertain final fsync.
const std = @import("std");
const record = @import("interaction_record.zig");
const sync = @import("sync.zig");
var process_mutex: sync.Mutex = .{};
pub const maximum_file_bytes = 16 * 1024 * 1024;
pub const Writer = struct {
    allocator: std.mem.Allocator,
    directory: [:0]u8,
    name: [:0]u8,
    lock_name: [:0]u8,
    pub fn init(a: std.mem.Allocator, path: []const u8) !Writer {
        if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidFilePath;
        const basename = std.fs.path.basename(path);
        if (basename.len == 0 or basename.len > 240 or std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..") or path[path.len - 1] == '/') return error.InvalidFilePath;
        const directory = try a.dupeSentinel(u8, std.fs.path.dirname(path) orelse ".", 0);
        errdefer a.free(directory);
        const name = try a.dupeSentinel(u8, basename, 0);
        errdefer a.free(name);
        const lock_name = try std.fmt.allocPrintSentinel(a, ".{s}.lock", .{basename}, 0);
        return .{ .allocator = a, .directory = directory, .name = name, .lock_name = lock_name };
    }
    pub fn deinit(self: Writer) void {
        self.allocator.free(self.directory);
        self.allocator.free(self.name);
        self.allocator.free(self.lock_name);
    }
    fn canonical(self: Writer, bytes: []const u8) !void {
        const value = record.decode(self.allocator, bytes) catch |err| {
            if (err == error.OutOfMemory) return err;
            return error.InvalidExistingJSONL;
        };
        defer value.deinit();
        const encoded = try value.value.encode(self.allocator);
        defer self.allocator.free(encoded);
        if (!std.mem.eql(u8, bytes, encoded)) return error.InvalidExistingJSONL;
    }
    fn existing(self: Writer, directory: std.c.fd_t) ![]u8 {
        const fd = std.c.openat(directory, self.name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true });
        if (fd < 0) {
            if (std.c.errno(fd) == .NOENT) return self.allocator.alloc(u8, 0);
            if (std.c.errno(fd) == .LOOP) return error.OutputIsSymbolicLink;
            return error.OpenOutputFailed;
        }
        defer _ = std.c.close(fd);
        var stat: std.c.Stat = undefined;
        if (std.c.fstat(fd, &stat) != 0) return error.InspectOutputFailed;
        if (stat.mode & std.c.S.IFMT != std.c.S.IFREG or stat.size < 0 or stat.size > maximum_file_bytes) return error.OutputTooLarge;
        const size: usize = @intCast(stat.size);
        const buffer = try self.allocator.alloc(u8, size + 1);
        defer self.allocator.free(buffer);
        var count: usize = 0;
        while (count < buffer.len) {
            const n = std.c.read(fd, buffer[count..].ptr, buffer.len - count);
            if (n < 0 and std.c.errno(n) == .INTR) continue;
            if (n < 0) return error.ReadOutputFailed;
            if (n == 0) break;
            count += @intCast(n);
        }
        if (count != size or (size != 0 and buffer[size - 1] != '\n')) return error.InvalidExistingJSONL;
        if (size != 0) {
            var lines = std.mem.splitScalar(u8, buffer[0 .. size - 1], '\n');
            while (lines.next()) |line| try self.canonical(line);
        }
        return self.allocator.dupe(u8, buffer[0..size]);
    }
    pub fn append(self: Writer, encoded: []const u8) !void {
        if (encoded.len >= record.maximum_record_bytes) return error.RecordTooLarge;
        try self.canonical(encoded);
        process_mutex.lock();
        defer process_mutex.unlock();
        const directory = std.c.open(self.directory, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true });
        if (directory < 0) return error.OutputDirectoryUnavailable;
        defer _ = std.c.close(directory);
        const lock_fd = std.c.openat(directory, self.lock_name, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, @as(c_uint, 0o600));
        if (lock_fd < 0) {
            if (std.c.errno(lock_fd) == .LOOP) return error.OutputIsSymbolicLink;
            return error.OpenLockFailed;
        }
        defer _ = std.c.close(lock_fd);
        var metadata: std.c.Stat = undefined;
        if (std.c.fstat(lock_fd, &metadata) != 0 or metadata.mode & std.c.S.IFMT != std.c.S.IFREG) return error.InvalidLockFile;
        if (std.c.fchmod(lock_fd, 0o600) != 0) return error.ChmodLockFailed;
        var lock: std.c.Flock = .{ .start = 0, .len = 0, .pid = 0, .type = std.c.F.WRLCK, .whence = 0 };
        while (std.c.fcntl(lock_fd, std.c.F.SETLKW, &lock) < 0) {
            if (std.c.errno(-1) != .INTR) return error.LockFailed;
        }
        defer {
            lock.type = std.c.F.UNLCK;
            _ = std.c.fcntl(lock_fd, std.c.F.SETLK, &lock);
        }
        const old = try self.existing(directory);
        defer self.allocator.free(old);
        var lines = std.mem.splitScalar(u8, old, '\n');
        while (lines.next()) |line| if (std.mem.eql(u8, line, encoded)) {
            if (std.c.fsync(directory) != 0) return error.SyncDirectoryFailed;
            return;
        };
        if (encoded.len + 1 > maximum_file_bytes - old.len) return error.OutputTooLarge;
        var random: [16]u8 = undefined;
        std.c.arc4random_buf(&random, random.len);
        const hex = std.fmt.bytesToHex(random, .lower);
        var temp_buffer: [64]u8 = undefined;
        const temporary = try std.fmt.bufPrintSentinel(&temp_buffer, ".spice-trace-{s}.tmp", .{hex}, 0);
        const fd = std.c.openat(directory, temporary, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0o600));
        if (fd < 0) return error.OpenTemporaryFailed;
        defer _ = std.c.close(fd);
        var renamed = false;
        defer if (!renamed) {
            _ = std.c.unlinkat(directory, temporary, 0);
        };
        if (std.c.fchmod(fd, 0o600) != 0) return error.ChmodTemporaryFailed;
        try write(fd, old);
        try write(fd, encoded);
        try write(fd, "\n");
        if (std.c.fsync(fd) != 0) return error.SyncTemporaryFailed;
        if (std.c.renameat(directory, temporary, directory, self.name) != 0) return error.ReplaceOutputFailed;
        renamed = true;
        if (std.c.fsync(directory) != 0) return error.SyncDirectoryFailed;
    }
};
fn write(fd: std.c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        if (n <= 0) return error.WriteOutputFailed;
        offset += @intCast(n);
    }
}
