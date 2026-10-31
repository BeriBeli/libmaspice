//! Blocking WebDAV operations. Call from the bounded filesystem executor, never
//! a channel reader. Root is immutable, explicitly selected, and read-only unless
//! opted in. Each response owns bounded bytes; failed writes are never retried.
const std = @import("std");
const http = @import("webdav_http.zig");
const paths = @import("webdav_path.zig");
extern "c" fn removefileat(c_int, [*:0]const u8, ?*anyopaque, u32) c_int;
extern "c" fn spice_zig_webdav_date(f64, *?[*]u8, *usize) c_int;
const Owned = struct {
    response: http.Response,
    allocation: ?[]u8 = null,
    fn deinit(self: Owned, a: std.mem.Allocator) void {
        if (self.allocation) |data| a.free(data);
    }
};
fn response(status: u16) Owned {
    return .{ .response = .{ .status = status } };
}
fn kind(stat: std.c.Stat) u16 {
    return stat.mode & std.c.S.IFMT;
}
fn fstat(fd: std.c.fd_t) !std.c.Stat {
    var value: std.c.Stat = undefined;
    if (std.c.fstat(fd, &value) != 0 or value.size < 0) return error.FileOperationFailed;
    return value;
}
const Fragment = struct { sort: []u8, bytes: []u8 };
fn less(_: void, lhs: Fragment, rhs: Fragment) bool {
    return std.mem.order(u8, lhs.sort, rhs.sort) == .lt;
}
const prefix = "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\">";
const suffix = "</D:multistatus>";
pub const Filesystem = struct {
    root: paths.Root,
    read_write: bool = false,
    maximum_body: usize = 64 * 1024 * 1024,
    pub fn open(a: std.mem.Allocator, path: []const u8, read_write: bool, maximum_body: usize) !Filesystem {
        if (maximum_body > std.math.maxInt(isize) - 4096) return error.InvalidLimits;
        return .{ .root = try paths.Root.open(a, path), .read_write = read_write, .maximum_body = maximum_body };
    }
    pub fn deinit(self: Filesystem) void {
        self.root.deinit();
    }
    pub fn execute(self: *const Filesystem, request: http.Request) ![]u8 {
        const result = self.handle(request) catch |err| blk: {
            if (err == error.OutOfMemory or err == error.WriteFailed) return error.OutOfMemory;
            break :blk response(if (err == error.PathEscapesRoot) 403 else 500);
        };
        defer result.deinit(self.root.allocator);
        return result.response.encode(self.root.allocator, !std.mem.eql(u8, request.method, "HEAD"));
    }
    fn handle(self: *const Filesystem, r: http.Request) !Owned {
        const m = r.method;
        if (std.mem.eql(u8, m, "OPTIONS")) return .{ .response = .{ .status = 200, .allow = if (self.read_write) "OPTIONS, PROPFIND, GET, HEAD, PUT, MKCOL, DELETE, COPY, MOVE" else "OPTIONS, PROPFIND, GET, HEAD" } };
        if (std.mem.eql(u8, m, "GET") or std.mem.eql(u8, m, "HEAD")) return self.get(r);
        if (std.mem.eql(u8, m, "PROPFIND")) return self.propfind(r);
        if (std.mem.eql(u8, m, "PUT") or std.mem.eql(u8, m, "MKCOL") or std.mem.eql(u8, m, "DELETE") or std.mem.eql(u8, m, "COPY") or std.mem.eql(u8, m, "MOVE")) {
            if (!self.read_write) return response(403);
            if (std.mem.eql(u8, m, "MKCOL") and r.body.len != 0) return response(415);
            if (std.mem.eql(u8, m, "COPY") or std.mem.eql(u8, m, "MOVE")) return self.copyMove(r);
            const entry = self.root.resolve(r.target) catch |err| {
                if (err == error.NotFound) return response(if (std.mem.eql(u8, m, "DELETE")) 404 else 409);
                return err;
            };
            defer entry.deinit();
            const metadata = try self.existingMetadata(entry);
            if (std.mem.eql(u8, m, "DELETE")) {
                if (entry.is_root) return response(403);
                if (metadata == null) return response(404);
                if (removefileat(entry.parent, entry.name, null, 1 | 128) != 0) return error.FileOperationFailed;
                return response(204);
            }
            if (std.mem.eql(u8, m, "MKCOL")) {
                if (metadata != null) return response(405);
                if (std.c.mkdirat(entry.parent, entry.name, 0o777) != 0) return error.FileOperationFailed;
                return response(201);
            }
            if (r.body.len > self.maximum_body) return response(413);
            if (metadata) |stat| {
                if (kind(stat) == std.c.S.IFDIR) return response(405);
                // A symlink to a directory also counts as a directory in FileManager.
                if (kind(stat) == std.c.S.IFLNK) {
                    if (kind(try self.root.metadata(entry)) == std.c.S.IFDIR) return response(405);
                }
            }
            try atomicWrite(entry, r.body, try entry.stat());
            return response(if (metadata != null) 204 else 201);
        }
        return response(405);
    }
    fn existingMetadata(self: *const Filesystem, entry: paths.Entry) !?std.c.Stat {
        const metadata = (try entry.stat()) orelse return null;
        if (kind(metadata) == std.c.S.IFLNK) {
            _ = self.root.metadata(entry) catch |err| {
                if (err == error.NotFound) return null;
                return err;
            };
        }
        return metadata;
    }
    fn get(self: *const Filesystem, r: http.Request) !Owned {
        const entry = self.root.resolve(r.target) catch |err| {
            if (err == error.NotFound) return response(404);
            return err;
        };
        defer entry.deinit();
        const metadata = (try self.existingMetadata(entry)) orelse return response(404);
        const resolved_metadata = self.root.metadata(entry) catch |err| {
            if (err == error.NotFound) return response(404);
            return err;
        };
        if (kind(resolved_metadata) == std.c.S.IFDIR) return response(405);
        if (metadata.size < 0 or metadata.size > self.maximum_body) return response(413);
        const fd = self.root.openResolved(entry) catch |err| {
            if (err == error.NotFound) return response(404);
            return err;
        };
        defer _ = std.c.close(fd);
        const actual = try fstat(fd);
        if (kind(actual) == std.c.S.IFDIR) return response(405);
        if (std.mem.eql(u8, r.method, "HEAD")) return .{ .response = .{ .status = 200, .content_length = @intCast(metadata.size), .content_type = "application/octet-stream" } };
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.root.allocator);
        if (actual.size > self.maximum_body) return response(413);
        try bytes.ensureTotalCapacity(self.root.allocator, @intCast(actual.size));
        var buffer: [64 * 1024]u8 = undefined;
        while (true) {
            const count = std.c.read(fd, &buffer, buffer.len);
            if (count < 0) {
                if (std.c.errno(count) == .INTR) continue;
                return error.FileOperationFailed;
            }
            if (count == 0) break;
            const n: usize = @intCast(count);
            if (n > self.maximum_body - bytes.items.len) return response(413);
            try bytes.appendSlice(self.root.allocator, buffer[0..n]);
        }
        const owned = try bytes.toOwnedSlice(self.root.allocator);
        return .{ .response = .{ .status = 200, .content_type = "application/octet-stream", .body = owned }, .allocation = owned };
    }
    fn atomicWrite(entry: paths.Entry, body: []const u8, metadata: ?std.c.Stat) !void {
        var random: [16]u8 = undefined;
        std.c.arc4random_buf(&random, random.len);
        var temp_buffer: [64:0]u8 = @splat(0);
        const prefix_name = ".spice-zig-";
        @memcpy(temp_buffer[0..prefix_name.len], prefix_name);
        const hex = std.fmt.bytesToHex(random, .lower);
        @memcpy(temp_buffer[prefix_name.len..][0..hex.len], &hex);
        const name: [*:0]const u8 = &temp_buffer;
        const creation_mode: c_uint = if (metadata) |stat| stat.mode & 0o777 else 0o666;
        const fd = std.c.openat(entry.parent, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, creation_mode);
        if (fd < 0) return error.FileOperationFailed;
        defer _ = std.c.close(fd);
        var pending = true;
        defer if (pending) {
            _ = std.c.unlinkat(entry.parent, name, 0);
        };
        // Data.write(.atomic) preserves regular-file permission bits, but
        // creates a fresh inode (custom xattrs/old timestamps are not copied).
        // It succeeds even when the old file's contents cannot be read.
        if (metadata) |stat| if (kind(stat) == std.c.S.IFREG) {
            if (std.c.fchmod(fd, stat.mode & 0o777) != 0) return error.FileOperationFailed;
        };
        var offset: usize = 0;
        while (offset < body.len) {
            const n = std.c.write(fd, body[offset..].ptr, body.len - offset);
            if (n < 0 and std.c.errno(n) == .INTR) continue;
            if (n <= 0) return error.FileOperationFailed;
            offset += @intCast(n);
        }
        if (std.c.renameat(entry.parent, name, entry.parent, entry.name) != 0) return error.FileOperationFailed;
        pending = false;
    }
    fn copyMove(self: *const Filesystem, r: http.Request) !Owned {
        const destination = r.header("destination") orelse return response(400);
        const source = self.root.resolve(r.target) catch |err| {
            if (err == error.NotFound) return response(404);
            return err;
        };
        defer source.deinit();
        const maybe_target: ?paths.Entry = self.root.resolve(destination) catch |err| blk: {
            if (err == error.NotFound) break :blk null;
            return err;
        };
        defer if (maybe_target) |entry| entry.deinit();
        const metadata = (try self.existingMetadata(source)) orelse return response(404);
        if (source.is_root or (if (maybe_target) |entry| entry.is_root else false)) return response(404);
        const resolved_metadata = self.root.metadata(source) catch |err| {
            if (err == error.NotFound) return response(404);
            return err;
        };
        if (kind(resolved_metadata) == std.c.S.IFDIR) return response(405);
        if (metadata.size < 0 or metadata.size > self.maximum_body) return response(413);
        const target = maybe_target orelse return response(409);
        const previous = try self.existingMetadata(target);
        // Preserve source on self-copy/self-move instead of deleting it before error.
        if (previous) |stat| if (stat.dev == metadata.dev and stat.ino == metadata.ino) return response(409);
        if (previous != null) {
            if (r.header("overwrite")) |value| {
                const upper = try http.transform(self.root.allocator, value, .upper, false);
                defer self.root.allocator.free(upper);
                if (std.mem.eql(u8, upper, "F")) return response(412);
            }
            if (removefileat(target.parent, target.name, null, 1 | 128) != 0) return error.FileOperationFailed;
        }
        const move = std.mem.eql(u8, r.method, "MOVE");
        if (move) {
            if (std.c.renameat(source.parent, source.name, target.parent, target.name) == 0) return response(if (previous != null) 204 else 201);
            if (std.c.errno(-1) != .XDEV) return error.FileOperationFailed;
        }
        if (kind(metadata) == std.c.S.IFLNK) {
            var text: [4097]u8 = undefined;
            const n = std.c.readlinkat(source.parent, source.name, &text, text.len - 1);
            if (n < 0 or n >= text.len - 1) return error.FileOperationFailed;
            text[@intCast(n)] = 0;
            if (std.c.symlinkat(@ptrCast(&text), target.parent, target.name) != 0) return error.FileOperationFailed;
        } else {
            const fd = try self.root.openResolved(source);
            defer _ = std.c.close(fd);
            const output = std.c.openat(target.parent, target.name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c_uint, 0o666));
            if (output < 0) return error.FileOperationFailed;
            defer _ = std.c.close(output);
            var buffer: [64 * 1024]u8 = undefined;
            var copied: usize = 0;
            while (true) {
                const count = std.c.read(fd, &buffer, buffer.len);
                if (count < 0 and std.c.errno(count) == .INTR) continue;
                if (count < 0) return error.FileOperationFailed;
                if (count == 0) break;
                const n: usize = @intCast(count);
                if (n > self.maximum_body - copied) return error.FileOperationFailed;
                var offset: usize = 0;
                while (offset < n) {
                    const written = std.c.write(output, buffer[offset..].ptr, n - offset);
                    if (written < 0 and std.c.errno(written) == .INTR) continue;
                    if (written <= 0) return error.FileOperationFailed;
                    offset += @intCast(written);
                }
                copied += n;
            }
            if (std.c.fcopyfile(fd, output, null, .{ .STAT = true, .ACL = true, .XATTR = true }) != 0) return error.FileOperationFailed;
        }
        if (move and std.c.unlinkat(source.parent, source.name, 0) != 0) return error.FileOperationFailed;
        return response(if (previous != null) 204 else 201);
    }
    fn propfind(self: *const Filesystem, r: http.Request) !Owned {
        const entry = self.root.resolve(r.target) catch |err| {
            if (err == error.NotFound) return response(404);
            return err;
        };
        defer entry.deinit();
        const metadata = self.root.metadata(entry) catch |err| {
            if (err == error.NotFound) return response(404);
            return err;
        };
        const depth = r.header("depth") orelse "infinity";
        if (!std.mem.eql(u8, depth, "0") and !std.mem.eql(u8, depth, "1")) return response(403);
        const root_fragment = try self.property(entry.canonical, metadata);
        defer self.root.allocator.free(root_fragment);
        if (prefix.len + suffix.len > self.maximum_body or root_fragment.len > self.maximum_body - prefix.len - suffix.len) return response(507);
        var total = prefix.len + suffix.len + root_fragment.len;
        var children: std.ArrayList(Fragment) = .empty;
        defer {
            for (children.items) |child| {
                self.root.allocator.free(child.sort);
                self.root.allocator.free(child.bytes);
            }
            children.deinit(self.root.allocator);
        }
        if (std.mem.eql(u8, depth, "1") and kind(metadata) == std.c.S.IFDIR) {
            const dirfd = try self.root.directoryForEnumeration(entry.canonical);
            const dir = std.c.fdopendir(dirfd) orelse {
                _ = std.c.close(dirfd);
                return error.FileOperationFailed;
            };
            defer _ = std.c.closedir(dir);
            while (true) {
                std.c._errno().* = 0;
                const value = std.c.readdir(dir) orelse {
                    if (std.c._errno().* != 0) return error.FileOperationFailed;
                    break;
                };
                const name = value.name[0..value.namlen];
                if (name.len == 0 or name[0] == '.') continue;
                if (children.items.len >= 4096) return response(507);
                const child_path = try std.fmt.allocPrint(self.root.allocator, "/{s}/{s}", .{ entry.canonical, name });
                defer self.root.allocator.free(child_path);
                const child = try self.root.resolvePath(child_path);
                defer child.deinit();
                const child_metadata = try self.root.metadata(child);
                // Foundation skips both dot files and the native UF_HIDDEN flag.
                if (child_metadata.flags & 0x8000 != 0) continue;
                const fragment = try self.property(child.canonical, child_metadata);
                errdefer self.root.allocator.free(fragment);
                if (fragment.len > self.maximum_body - total) {
                    self.root.allocator.free(fragment);
                    return response(507);
                }
                const key = try http.transform(self.root.allocator, name, .unchanged, true);
                errdefer self.root.allocator.free(key);
                try children.append(self.root.allocator, .{ .sort = key, .bytes = fragment });
                total += fragment.len;
            }
        }
        std.mem.sort(Fragment, children.items, {}, less);
        const body = try self.root.allocator.alloc(u8, total);
        var offset: usize = 0;
        for ([_][]const u8{ prefix, root_fragment }) |bytes| {
            @memcpy(body[offset..][0..bytes.len], bytes);
            offset += bytes.len;
        }
        for (children.items) |child| {
            @memcpy(body[offset..][0..child.bytes.len], child.bytes);
            offset += child.bytes.len;
        }
        @memcpy(body[offset..], suffix);
        return .{ .response = .{ .status = 207, .body = body, .content_type = "application/xml; charset=utf-8" }, .allocation = body };
    }
    fn property(self: *const Filesystem, relative: []const u8, metadata: std.c.Stat) ![]u8 {
        const a = self.root.allocator;
        const directory = kind(metadata) == std.c.S.IFDIR;
        const path = try std.fmt.allocPrint(a, "/{s}{s}", .{ relative, if (directory and relative.len != 0) "/" else "" });
        defer a.free(path);
        const href = (try paths.converted(a, 3, path)) orelse return error.InvalidRequest;
        defer a.free(href);
        const name = if (relative.len == 0) "/" else if (std.mem.lastIndexOfScalar(u8, relative, '/')) |i| relative[i + 1 ..] else relative;
        const time = metadata.mtime();
        const seconds = @as(f64, @floatFromInt(time.sec)) + @as(f64, @floatFromInt(time.nsec)) / 1e9;
        var raw: ?[*]u8 = null;
        var count: usize = 0;
        const date_result = spice_zig_webdav_date(seconds, &raw, &count);
        if (date_result == -2) return error.OutOfMemory;
        if (date_result != 0) return error.FileOperationFailed;
        defer std.c.free(raw);
        const etag = try std.fmt.allocPrint(a, "\"{x}-{x}\"", .{ @as(u64, @intCast(metadata.size)), @as(i64, time.sec + @as(i64, if (time.sec < 0 and time.nsec != 0) 1 else 0)) });
        defer a.free(etag);
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("<D:response><D:href>");
        try xml(w, href);
        try w.writeAll("</D:href><D:propstat><D:prop><D:displayname>");
        try xml(w, name);
        try w.print("</D:displayname><D:resourcetype>{s}</D:resourcetype><D:getcontentlength>{d}</D:getcontentlength><D:getetag>", .{ if (directory) "<D:collection/>" else "", metadata.size });
        try xml(w, etag);
        try w.writeAll("</D:getetag><D:getlastmodified>");
        try xml(w, raw.?[0..count]);
        try w.writeAll("</D:getlastmodified></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>");
        return out.toOwnedSlice();
    }
};
fn xml(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&apos;"),
        else => try w.writeByte(byte),
    };
}
