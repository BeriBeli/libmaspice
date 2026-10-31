//! Root authorization and descriptor-relative path access. Foundation supplies
//! URL decoding/canonicalization. Zig enforces containment and opens each
//! canonical directory with NOFOLLOW, so path-check/open symlink replacement
//! fails closed. The explicit root descriptor remains pinned for its lifetime.
const std = @import("std");
extern "c" fn spice_zig_webdav_open_directory(c_int, [*:0]const u8) c_int;
extern "c" fn spice_zig_webdav_string(u32, [*]const u8, usize, *?[*]u8, *usize) c_int;
pub fn converted(a: std.mem.Allocator, operation: u32, input: []const u8) !?[]u8 {
    var raw: ?[*]u8 = null;
    var len: usize = 0;
    const result = spice_zig_webdav_string(operation, input.ptr, input.len, &raw, &len);
    if (result == 1) return null;
    if (result == -2) return error.OutOfMemory;
    if (result != 0) return error.InvalidRequest;
    defer std.c.free(raw);
    return try a.dupe(u8, raw.?[0..len]);
}
fn terminated(a: std.mem.Allocator, input: []const u8) ![:0]u8 {
    if (input.len > 4096 or std.mem.indexOfScalar(u8, input, 0) != null) return error.InvalidRequest;
    return a.dupeSentinel(u8, input, 0);
}
fn failure() anyerror {
    return switch (std.c.errno(-1)) {
        .NOENT, .NOTDIR => error.NotFound,
        .LOOP => error.PathEscapesRoot,
        else => error.FileOperationFailed,
    };
}
pub const Entry = struct {
    allocator: std.mem.Allocator,
    parent: std.c.fd_t,
    name: [:0]u8,
    canonical: []u8,
    is_root: bool,
    pub fn deinit(self: Entry) void {
        _ = std.c.close(self.parent);
        self.allocator.free(self.name);
        self.allocator.free(self.canonical);
    }
    /// Metadata of the original leaf: atomic PUT replaces a symlink, DELETE
    /// removes the link itself, and COPY preserves it, as Foundation does.
    pub fn stat(self: Entry) !?std.c.Stat {
        var value: std.c.Stat = undefined;
        if (std.c.fstatat(self.parent, self.name, &value, std.c.AT.SYMLINK_NOFOLLOW) != 0) {
            const err = failure();
            if (err == error.NotFound) return null;
            return err;
        }
        return value;
    }
};
pub const Root = struct {
    allocator: std.mem.Allocator,
    fd: std.c.fd_t,
    path: []u8,
    pub fn open(a: std.mem.Allocator, path: []const u8) !Root {
        if (path.len == 0 or path[0] != '/') return error.InvalidRoot;
        const normalized = (try converted(a, 2, path)) orelse return error.InvalidRoot;
        errdefer a.free(normalized);
        const z = try terminated(a, normalized);
        defer a.free(z);
        const fd = spice_zig_webdav_open_directory(std.c.AT.FDCWD, z);
        if (fd < 0) return error.InvalidRoot;
        return .{ .allocator = a, .fd = fd, .path = normalized };
    }
    pub fn deinit(self: Root) void {
        _ = std.c.close(self.fd);
        self.allocator.free(self.path);
    }
    fn relative(self: Root, absolute: []const u8) ![]const u8 {
        if (std.mem.eql(u8, absolute, self.path)) return "";
        if (std.mem.eql(u8, self.path, "/") and std.mem.startsWith(u8, absolute, "/")) return absolute[1..];
        if (absolute.len <= self.path.len or !std.mem.startsWith(u8, absolute, self.path) or absolute[self.path.len] != '/') return error.PathEscapesRoot;
        return absolute[self.path.len + 1 ..];
    }
    pub fn directory(self: Root, relative_path: []const u8) !std.c.fd_t {
        var fd = std.c.fcntl(self.fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
        if (fd < 0) return error.FileOperationFailed;
        errdefer _ = std.c.close(fd);
        var pieces = std.mem.tokenizeScalar(u8, relative_path, '/');
        while (pieces.next()) |piece| {
            if (std.mem.eql(u8, piece, ".") or std.mem.eql(u8, piece, "..")) return error.PathEscapesRoot;
            const z = try terminated(self.allocator, piece);
            defer self.allocator.free(z);
            const next = spice_zig_webdav_open_directory(fd, z);
            if (next < 0) return failure();
            _ = std.c.close(fd);
            fd = next;
        }
        return fd;
    }
    pub fn decode(self: Root, target: []const u8) ![]u8 {
        if (target.len > 65536 or !std.unicode.utf8ValidateSlice(target)) return error.InvalidRequest;
        var path: ?[]u8 = null;
        if (std.mem.indexOf(u8, target, "://") != null) path = try converted(self.allocator, 0, target);
        if (path == null) {
            // URL path query stripping uses Character semantics, just like HTTP fields.
            var separators = try @import("webdav_http.zig").Separators.init(target);
            defer separators.deinit();
            var start: usize = 0;
            while (true) {
                const end = separators.next('?') orelse target.len;
                if (end > start or end == target.len) {
                    path = try converted(self.allocator, 1, target[start..end]);
                    break;
                }
                start = end + 1;
            }
        }
        const decoded = path orelse return error.InvalidRequest;
        errdefer self.allocator.free(decoded);
        if (decoded.len == 0 or decoded[0] != '/') return error.InvalidRequest;
        var iterator = (try std.unicode.Utf8View.init(decoded)).iterator();
        while (iterator.nextCodepoint()) |cp| if (cp < 32 or cp == 127) return error.InvalidRequest;
        var parts = std.mem.tokenizeScalar(u8, decoded, '/');
        while (parts.next()) |piece| if (std.mem.eql(u8, piece, ".") or std.mem.eql(u8, piece, "..")) return error.PathEscapesRoot;
        return decoded;
    }
    pub fn resolve(self: Root, target: []const u8) !Entry {
        const decoded = try self.decode(target);
        defer self.allocator.free(decoded);
        return self.resolvePath(decoded);
    }
    /// Internal entry paths have already passed URL decoding. Never decode twice.
    pub fn resolvePath(self: Root, decoded: []const u8) !Entry {
        if (decoded.len == 0 or decoded[0] != '/' or decoded.len > 65536 or !std.unicode.utf8ValidateSlice(decoded)) return error.InvalidRequest;
        var path: std.ArrayList(u8) = .empty;
        defer path.deinit(self.allocator);
        try path.appendSlice(self.allocator, self.path);
        var components = std.mem.tokenizeScalar(u8, decoded, '/');
        var last: []const u8 = ".";
        var parent_length = self.path.len;
        while (components.next()) |piece| {
            if (std.mem.eql(u8, piece, ".") or std.mem.eql(u8, piece, "..") or std.mem.indexOfScalar(u8, piece, 0) != null) return error.PathEscapesRoot;
            parent_length = path.items.len;
            last = piece;
            if (path.items.len == 0 or path.items[path.items.len - 1] != '/') try path.append(self.allocator, '/');
            try path.appendSlice(self.allocator, piece);
        }
        const canonical = (try converted(self.allocator, 2, path.items)) orelse return error.InvalidRequest;
        defer self.allocator.free(canonical);
        const relative_path = try self.relative(canonical);
        const canonical_parent = (try converted(self.allocator, 2, path.items[0..parent_length])) orelse return error.InvalidRequest;
        defer self.allocator.free(canonical_parent);
        const parent = try self.directory(try self.relative(canonical_parent));
        errdefer _ = std.c.close(parent);
        const name = try terminated(self.allocator, last);
        errdefer self.allocator.free(name);
        return .{ .allocator = self.allocator, .parent = parent, .name = name, .canonical = try self.allocator.dupe(u8, relative_path), .is_root = last.len == 1 and last[0] == '.' };
    }
    /// Reads the resolved leaf using only descriptor-relative NOFOLLOW opens.
    /// Special files are rejected before any blocking read or unbounded stream.
    pub fn metadata(self: Root, entry: Entry) !std.c.Stat {
        var value: std.c.Stat = undefined;
        if (entry.canonical.len == 0) {
            if (std.c.fstat(self.fd, &value) != 0) return error.FileOperationFailed;
        } else {
            const slash = std.mem.lastIndexOfScalar(u8, entry.canonical, '/');
            const parent = try self.directory(if (slash) |i| entry.canonical[0..i] else "");
            defer _ = std.c.close(parent);
            const leaf = if (slash) |i| entry.canonical[i + 1 ..] else entry.canonical;
            const z = try terminated(self.allocator, leaf);
            defer self.allocator.free(z);
            if (std.c.fstatat(parent, z, &value, std.c.AT.SYMLINK_NOFOLLOW) != 0) return failure();
            if (value.mode & std.c.S.IFMT == std.c.S.IFLNK) return error.NotFound;
        }
        if (value.size < 0) return error.FileOperationFailed;
        return value;
    }
    pub fn directoryForEnumeration(self: Root, relative_path: []const u8) !std.c.fd_t {
        const anchor = try self.directory(relative_path);
        defer _ = std.c.close(anchor);
        const fd = std.c.openat(anchor, ".", .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true, .NOFOLLOW = true });
        if (fd < 0) return failure();
        return fd;
    }
    pub fn openResolved(self: Root, entry: Entry) !std.c.fd_t {
        if (entry.canonical.len == 0) return self.directory("");
        const slash = std.mem.lastIndexOfScalar(u8, entry.canonical, '/');
        const parent = try self.directory(if (slash) |i| entry.canonical[0..i] else "");
        defer _ = std.c.close(parent);
        const leaf = if (slash) |i| entry.canonical[i + 1 ..] else entry.canonical;
        const z = try terminated(self.allocator, leaf);
        defer self.allocator.free(z);
        const fd = std.c.openat(parent, z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true });
        if (fd < 0) {
            // Foundation leaves dangling/looping leaf links unresolved. The
            // NOFOLLOW open still refuses them; public fileExists semantics
            // classify that leaf as absent.
            if (std.c.errno(fd) == .LOOP) return error.NotFound;
            return failure();
        }
        errdefer _ = std.c.close(fd);
        var stat: std.c.Stat = undefined;
        if (std.c.fstat(fd, &stat) != 0) return error.FileOperationFailed;
        const kind = stat.mode & std.c.S.IFMT;
        if (kind != std.c.S.IFREG and kind != std.c.S.IFDIR) return error.NotRegularFile;
        return fd;
    }
};
