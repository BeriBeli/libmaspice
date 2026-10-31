//! Immutable TLS policy retained independently by native verification blocks.
const std = @import("std");
const subject = @import("subject.zig");
pub const DER = extern struct { data: [*]const u8, size: usize };
extern fn spice_sec_certificate_valid([*]const u8, usize) c_int;
extern fn spice_sec_evaluate(*anyopaque, c_int, [*]const DER, usize, ?[*:0]const u8) c_int;
extern fn spice_sec_subject(*anyopaque, *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) c_int, ?*anyopaque) c_int;
pub const Kind = enum(u8) { tcp, system, custom_ca, virt_viewer, insecure_for_testing_only };
pub const Config = struct {
    kind: Kind = .tcp,
    server_name: ?[]const u8 = null,
    certificates: []const []const u8 = &.{},
    expected_subject: []const u8 = "",
};
pub const Policy = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    kind: Kind,
    server_name: [:0]u8,
    expected_subject: []u8,
    certificates: std.ArrayList(DER) = .empty,

    pub fn create(allocator: std.mem.Allocator, host: []const u8, config: Config) !*Policy {
        const name = config.server_name orelse host;
        if (name.len == 0 or name.len > 4096 or std.mem.indexOfScalar(u8, name, 0) != null or !std.unicode.utf8ValidateSlice(name)) return error.InvalidConfiguration;
        if (config.expected_subject.len > 16384 or (config.kind == .virt_viewer and config.expected_subject.len == 0)) return error.InvalidConfiguration;
        const self = try allocator.create(Policy);
        errdefer allocator.destroy(self);
        const server_name = try allocator.dupeSentinel(u8, name, 0);
        errdefer allocator.free(server_name);
        const expected = try allocator.dupe(u8, config.expected_subject);
        self.* = .{ .allocator = allocator, .kind = config.kind, .server_name = server_name, .expected_subject = expected };
        errdefer {
            for (self.certificates.items) |cert| allocator.free(cert.data[0..cert.size]);
            self.certificates.deinit(allocator);
            allocator.free(expected);
        }
        if (config.kind == .custom_ca or config.kind == .virt_viewer) {
            var total: usize = 0;
            for (config.certificates) |input| {
                if (input.len > 16 * 1024 * 1024 - total) return error.MessageTooLarge;
                total += input.len;
                try self.addRepresentation(input);
            }
            if (self.certificates.items.len == 0) return error.InvalidCertificate;
        }
        return self;
    }
    fn append(self: *Policy, bytes: []const u8) !void {
        if (self.certificates.items.len >= 4096) return error.MessageTooLarge;
        if (spice_sec_certificate_valid(bytes.ptr, bytes.len) == 0) return error.InvalidCertificate;
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);
        try self.certificates.append(self.allocator, .{ .data = copy.ptr, .size = copy.len });
    }
    fn addRepresentation(self: *Policy, bytes: []const u8) !void {
        if (spice_sec_certificate_valid(bytes.ptr, bytes.len) != 0) return self.append(bytes);
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidCertificate;
        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(self.allocator);
        var index: usize = 0;
        while (index < bytes.len) : (index += 1) {
            if (bytes[index] == '\\' and index + 1 < bytes.len and bytes[index + 1] == 'n') {
                try normalized.append(self.allocator, 10);
                index += 1;
            } else try normalized.append(self.allocator, bytes[index]);
        }
        const begin = "-----BEGIN CERTIFICATE-----";
        const end = "-----END CERTIFICATE-----";
        var remaining: []const u8 = normalized.items;
        var count: usize = 0;
        while (std.mem.indexOf(u8, remaining, begin)) |start| {
            remaining = remaining[start + begin.len ..];
            const stop = std.mem.indexOf(u8, remaining, end) orelse return error.InvalidCertificate;
            var encoded: std.ArrayList(u8) = .empty;
            defer encoded.deinit(self.allocator);
            for (remaining[0..stop]) |byte| {
                if (std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '/' or byte == '=') try encoded.append(self.allocator, byte);
            }
            const decoder = std.base64.standard.Decoder;
            const size = decoder.calcSizeForSlice(encoded.items) catch return error.InvalidCertificate;
            const decoded = try self.allocator.alloc(u8, size);
            defer self.allocator.free(decoded);
            decoder.decode(decoded, encoded.items) catch return error.InvalidCertificate;
            try self.append(decoded);
            count += 1;
            remaining = remaining[stop + end.len ..];
        }
        if (count == 0) return error.InvalidCertificate;
    }
    pub fn retain(self: *Policy) *Policy {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old > 0 and old < std.math.maxInt(usize));
        return self;
    }
    pub fn release(self: *Policy) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            const allocator = self.allocator;
            for (self.certificates.items) |cert| allocator.free(cert.data[0..cert.size]);
            self.certificates.deinit(allocator);
            allocator.free(self.server_name);
            allocator.free(self.expected_subject);
            allocator.destroy(self);
        }
    }
    pub fn releaseCallback(context: ?*anyopaque) callconv(.c) void {
        const self: *Policy = @ptrCast(@alignCast(context.?));
        self.release();
    }
    pub fn verify(context: ?*anyopaque, trust: ?*anyopaque) callconv(.c) c_int {
        const self: *Policy = @ptrCast(@alignCast(context.?));
        if (self.kind == .insecure_for_testing_only) return 1;
        const native_trust = trust orelse return 0;
        if (spice_sec_evaluate(native_trust, @backingInt(self.kind), self.certificates.items.ptr, self.certificates.items.len, self.server_name.ptr) == 0) return 0;
        if (self.kind == .virt_viewer) return spice_sec_subject(native_trust, matches, self);
        return 1;
    }
    fn matches(context: ?*anyopaque, bytes: [*]const u8, size: usize) callconv(.c) c_int {
        const self: *Policy = @ptrCast(@alignCast(context.?));
        return @intFromBool(subject.matches(self.expected_subject, bytes[0..size]));
    }
};
