//! Bounded HTTP/1 request parsing for the existing native WebDAV subset.
//! A Request owns all its bytes. Parsing never mutates caller state, including
//! on incomplete input, malformed headers, sequence exhaustion or allocation failure.
const std = @import("std");
const CF = opaque {};
const Range = extern struct { location: isize, length: isize };
extern "c" fn CFStringCreateMutable(?*const anyopaque, isize) ?*CF;
extern "c" fn CFStringAppendCharacters(*CF, [*]const u16, isize) void;
extern "c" fn CFStringLowercase(*CF, ?*const anyopaque) void;
extern "c" fn CFStringUppercase(*CF, ?*const anyopaque) void;
extern "c" fn CFStringNormalize(*CF, isize) void;
extern "c" fn CFStringGetLength(*CF) isize;
extern "c" fn CFStringGetRangeOfComposedCharactersAtIndex(*CF, isize) Range;
extern "c" fn CFStringGetBytes(*CF, Range, u32, u8, u8, ?[*]u8, isize, *isize) isize;
extern "c" fn CFRelease(*CF) void;
extern "c" fn CFCharacterSetGetPredefined(isize) *const anyopaque;
extern "c" fn CFCharacterSetIsLongCharacterMember(*const anyopaque, u32) u8;
const utf8 = 0x08000100;
fn nativeString(input: []const u8) !*CF {
    var iterator = (std.unicode.Utf8View.init(input) catch return error.InvalidRequest).iterator();
    const value = CFStringCreateMutable(null, 0) orelse return error.OutOfMemory;
    // Construct characters directly: CF's UTF-8 byte initializer consumes a
    // leading BOM, whereas an already-decoded Swift substring preserves it.
    var buffer: [128]u16 = undefined;
    var count: usize = 0;
    while (iterator.nextCodepoint()) |cp| {
        if (count > buffer.len - 2) {
            CFStringAppendCharacters(value, &buffer, @intCast(count));
            count = 0;
        }
        if (cp <= 0xffff) {
            buffer[count] = @intCast(cp);
            count += 1;
        } else {
            const n = cp - 0x10000;
            buffer[count] = @intCast(0xd800 + (n >> 10));
            buffer[count + 1] = @intCast(0xdc00 + (n & 0x3ff));
            count += 2;
        }
    }
    if (count != 0) CFStringAppendCharacters(value, &buffer, @intCast(count));
    return value;
}
pub const Case = enum { unchanged, lower, upper };
/// Native Unicode tables retain Foundation's case conversion and canonical
/// equivalence. Protocol framing, admission and ownership stay in Zig.
pub fn transform(a: std.mem.Allocator, input: []const u8, mode: Case, canonical: bool) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(input) or input.len > std.math.maxInt(isize)) return error.InvalidRequest;
    const value = try nativeString(input);
    defer CFRelease(value);
    switch (mode) {
        .unchanged => {},
        .lower => CFStringLowercase(value, null),
        .upper => CFStringUppercase(value, null),
    }
    if (canonical) CFStringNormalize(value, 2); // NFC, matching Swift String equality.
    const range: Range = .{ .location = 0, .length = CFStringGetLength(value) };
    var count: isize = 0;
    if (CFStringGetBytes(value, range, utf8, 0, 0, null, 0, &count) != range.length or count < 0) return error.InvalidRequest;
    const result = try a.alloc(u8, @intCast(count));
    errdefer a.free(result);
    if (CFStringGetBytes(value, range, utf8, 0, 0, result.ptr, count, &count) != range.length or count != result.len) return error.InvalidRequest;
    return result;
}
fn trim(input: []const u8) []const u8 {
    const set = CFCharacterSetGetPredefined(2); // whitespaces, not newlines
    var iterator = std.unicode.Utf8View.initUnchecked(input).iterator();
    var first: ?usize = null;
    var end: usize = 0;
    while (iterator.nextCodepoint()) |cp| {
        if (CFCharacterSetIsLongCharacterMember(set, cp) == 0) {
            if (first == null) first = iterator.i - (std.unicode.utf8CodepointSequenceLength(cp) catch unreachable);
            end = iterator.i;
        }
    }
    return if (first) |start| input[start..end] else input[0..0];
}
// Swift searches a Character separator, so a space/colon followed by a
// combining scalar is not that separator. Foundation supplies Unicode grapheme
// boundaries; the framing and token count are still checked here.
pub const Separators = struct {
    value: *CF,
    iterator: std.unicode.Utf8Iterator,
    utf16: isize = 0,
    pub fn init(input: []const u8) !Separators {
        return .{ .value = try nativeString(input), .iterator = std.unicode.Utf8View.initUnchecked(input).iterator() };
    }
    pub fn deinit(self: Separators) void {
        CFRelease(self.value);
    }
    pub fn next(self: *Separators, separator: u8) ?usize {
        while (true) {
            const byte = self.iterator.i;
            const cp = self.iterator.nextCodepoint() orelse return null;
            const index = self.utf16;
            self.utf16 += if (cp > 0xffff) @as(isize, 2) else 1;
            if (cp == separator) {
                const cluster = CFStringGetRangeOfComposedCharactersAtIndex(self.value, index);
                if (cluster.location == index and cluster.length == 1) return byte;
            }
        }
    }
};
pub const Limits = struct { header_bytes: usize = 64 * 1024, body_bytes: usize = 64 * 1024 * 1024 };
pub const Header = struct { key: []u8, value: []u8 };
pub const Request = struct {
    allocator: std.mem.Allocator,
    method: []u8,
    target: []u8,
    headers: []Header,
    body: []u8,
    consumed: usize,
    retained: usize,
    response_limit: usize,
    sequence: u64,
    pub fn header(self: Request, key: []const u8) ?[]const u8 {
        for (self.headers) |item| if (std.mem.eql(u8, item.key, key)) return item.value;
        return null;
    }
    pub fn deinit(self: Request) void {
        const a = self.allocator;
        a.free(self.method);
        a.free(self.target);
        a.free(self.body);
        for (self.headers) |h| {
            a.free(h.key);
            a.free(h.value);
        }
        a.free(self.headers);
    }
};
fn add(lhs: usize, rhs: usize) !usize {
    const result = std.math.add(usize, lhs, rhs) catch return error.BodyTooLarge;
    if (result > std.math.maxInt(isize)) return error.BodyTooLarge;
    return result;
}
fn contentLength(value: []const u8) !usize {
    if (value.len == 0) return error.InvalidRequest;
    const signed = value[0] == '+' or value[0] == '-';
    const digits = value[@intFromBool(signed)..];
    if (digits.len == 0) return error.InvalidRequest;
    var result: usize = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return error.InvalidRequest;
        result = std.math.mul(usize, result, 10) catch return error.InvalidRequest;
        result = std.math.add(usize, result, c - '0') catch return error.InvalidRequest;
        if (result > std.math.maxInt(isize)) return error.InvalidRequest;
    }
    if (value[0] == '-' and result != 0) return error.InvalidRequest;
    return result;
}
pub fn next(a: std.mem.Allocator, buffer: []const u8, sequence: u64, limits: Limits) !?Request {
    const delimiter = std.mem.indexOf(u8, buffer, "\r\n\r\n") orelse {
        if (buffer.len > limits.header_bytes) return error.HeaderTooLarge;
        return null;
    };
    const header_length = try add(delimiter, 4);
    if (header_length > limits.header_bytes) return error.HeaderTooLarge;
    const header_text = buffer[0..delimiter];
    const text = if (std.mem.startsWith(u8, header_text, "\xef\xbb\xbf")) header_text[3..] else header_text;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidRequest;
    var lines = std.mem.splitSequence(u8, text, "\r\n");
    const request_line = lines.next().?;
    var separators = try Separators.init(request_line);
    defer separators.deinit();
    var components: [3][]const u8 = undefined;
    var component_count: usize = 0;
    var start: usize = 0;
    while (true) {
        const end = separators.next(' ') orelse request_line.len;
        if (end > start) {
            if (component_count == 3) return error.InvalidRequest;
            components[component_count] = request_line[start..end];
            component_count += 1;
        }
        if (end == request_line.len) break;
        start = end + 1;
    }
    if (component_count != 3) return error.InvalidRequest;
    const method_input = components[0];
    const target_input = components[1];
    const version = components[2];
    if (!std.mem.eql(u8, version, "HTTP/1.0") and !std.mem.eql(u8, version, "HTTP/1.1")) return error.InvalidRequest;
    var headers: std.ArrayList(Header) = .empty;
    defer {
        for (headers.items) |h| {
            a.free(h.key);
            a.free(h.value);
        }
        headers.deinit(a);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    while (lines.next()) |line| {
        var line_separators = try Separators.init(line);
        defer line_separators.deinit();
        const colon = line_separators.next(':') orelse return error.InvalidRequest;
        const key = try transform(a, trim(line[0..colon]), .lower, true);
        errdefer a.free(key);
        if (key.len == 0) return error.InvalidRequest;
        if ((try seen.getOrPut(a, key)).found_existing) return error.InvalidRequest;
        const value = try a.dupe(u8, trim(line[colon + 1 ..]));
        errdefer a.free(value);
        try headers.append(a, .{ .key = key, .value = value });
    }
    var body_length: usize = 0;
    for (headers.items) |h| {
        if (std.mem.eql(u8, h.key, "transfer-encoding")) return error.InvalidRequest;
        if (std.mem.eql(u8, h.key, "content-length")) body_length = try contentLength(h.value);
    }
    if (body_length > limits.body_bytes) return error.BodyTooLarge;
    const request_length = try add(header_length, body_length);
    const maximum = try add(limits.header_bytes, limits.body_bytes);
    if (buffer.len < request_length) {
        if (buffer.len > maximum) return error.BodyTooLarge;
        return null;
    }
    if (sequence == std.math.maxInt(u64)) return error.InvalidRequest;
    const metadata = std.math.mul(usize, headers.items.len, 128) catch return error.BodyTooLarge;
    const retained = try add(try add(request_length, metadata), 512);
    const method = try transform(a, method_input, .upper, false);
    errdefer a.free(method);
    const response_limit = try add(4096, if (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "PROPFIND")) limits.body_bytes else 0);
    const target = try a.dupe(u8, target_input);
    errdefer a.free(target);
    const body = try a.dupe(u8, buffer[header_length..request_length]);
    errdefer a.free(body);
    return .{ .allocator = a, .method = method, .target = target, .headers = try headers.toOwnedSlice(a), .body = body, .consumed = request_length, .retained = retained, .response_limit = response_limit, .sequence = sequence + 1 };
}
/// A generated response uses only locally selected headers, never request text.
/// Lexical header order is stable and matches the current public Swift server.
pub const Response = struct {
    status: u16,
    body: []const u8 = &.{},
    content_length: ?usize = null,
    content_type: ?[]const u8 = null,
    allow: ?[]const u8 = null,
    pub fn encode(self: Response, a: std.mem.Allocator, include_body: bool) ![]u8 {
        return self.encodeImpl(a, include_body) catch return error.OutOfMemory;
    }
    fn encodeImpl(self: Response, a: std.mem.Allocator, include_body: bool) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        const w = &out.writer;
        try w.print("HTTP/1.1 {d} {s}\r\n", .{ self.status, reason(self.status) });
        if (self.allow) |allow| try w.print("Allow: {s}\r\n", .{allow});
        try w.print("Connection: keep-alive\r\nContent-Length: {d}\r\n", .{self.content_length orelse self.body.len});
        if (self.content_type) |kind| try w.print("Content-Type: {s}\r\n", .{kind});
        if (self.allow != null) try w.writeAll("DAV: 1\r\n");
        try w.writeAll("\r\n");
        if (include_body) try w.writeAll(self.body);
        return out.toOwnedSlice();
    }
};
fn reason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        207 => "Multi-Status",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        412 => "Precondition Failed",
        413 => "Content Too Large",
        415 => "Unsupported Media Type",
        507 => "Insufficient Storage",
        else => "Internal Server Error",
    };
}
