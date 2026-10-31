//! Owned endpoint/security configuration for asynchronous session preparation.
//! Migration inherits trust policy and never silently downgrades TLS.
const std = @import("std");
const tls = @import("tls.zig");
const migration = @import("migration.zig");
pub const Config = struct { host: []const u8, port: u16, tls: tls.Config = .{}, timeout_ms: u32 = 10000 };
pub const Owned = struct {
    allocator: std.mem.Allocator,
    config: Config,
    pub fn init(allocator: std.mem.Allocator, config: Config) !Owned {
        if (config.port == 0 or config.host.len == 0 or config.host.len > 4096 or std.mem.indexOfScalar(u8, config.host, 0) != null or !std.unicode.utf8ValidateSlice(config.host)) return error.InvalidConfiguration;
        if (config.tls.certificates.len > 4096 or config.tls.expected_subject.len > 16384) return error.InvalidConfiguration;
        if (config.tls.server_name) |name| {
            if (name.len == 0 or name.len > 4096 or std.mem.indexOfScalar(u8, name, 0) != null or !std.unicode.utf8ValidateSlice(name)) return error.InvalidConfiguration;
        }
        const host = try allocator.dupe(u8, config.host);
        errdefer allocator.free(host);
        const name = if (config.tls.server_name) |n| try allocator.dupe(u8, n) else null;
        errdefer if (name) |n| allocator.free(n);
        const subject = try allocator.dupe(u8, config.tls.expected_subject);
        errdefer allocator.free(subject);
        const certificates = try allocator.alloc([]const u8, config.tls.certificates.len);
        errdefer allocator.free(certificates);
        var copied: usize = 0;
        errdefer for (certificates[0..copied]) |cert| allocator.free(cert);
        var total: usize = 0;
        for (config.tls.certificates, certificates) |input, *output| {
            if (input.len > 16 * 1024 * 1024 - total) return error.MessageTooLarge;
            total += input.len;
            output.* = try allocator.dupe(u8, input);
            copied += 1;
        }
        return .{ .allocator = allocator, .config = .{ .host = host, .port = config.port, .timeout_ms = config.timeout_ms, .tls = .{ .kind = config.tls.kind, .server_name = name, .expected_subject = subject, .certificates = certificates } } };
    }
    pub fn deinit(self: Owned) void {
        self.allocator.free(self.config.host);
        if (self.config.tls.server_name) |name| self.allocator.free(name);
        self.allocator.free(self.config.tls.expected_subject);
        for (self.config.tls.certificates) |cert| self.allocator.free(cert);
        self.allocator.free(self.config.tls.certificates);
    }
};
pub fn destination(current: Config, target: migration.Destination) !Config {
    // Preserve the existing explicit unsupported subject-offer gate. Accepting
    // this field must never silently replace the caller's configured trust.
    if (target.subject != null) return error.UnsupportedMigrationSubject;
    var result = current;
    result.host = target.host;
    if (current.tls.kind != .tcp) {
        if (target.secure_port == 0) return error.TLSDowngrade;
        result.port = target.secure_port;
    } else if (target.port != 0) {
        result.port = target.port;
    } else if (target.secure_port != 0) {
        result.port = target.secure_port;
        result.tls = .{ .kind = .system };
    } else return error.InvalidPort;
    return result;
}
pub const Credentials = struct {
    bytes: [60]u8 = @splat(0),
    len: usize = 0,
    pub fn init(secret: []const u8) !Credentials {
        if (secret.len > 60) return error.PasswordTooLong;
        if (std.mem.indexOfScalar(u8, secret, 0) != null) return error.PasswordContainsNUL;
        var value: Credentials = .{ .len = secret.len };
        @memcpy(value.bytes[0..secret.len], secret);
        return value;
    }
    pub fn deinit(self: *Credentials) void {
        std.crypto.secureZero(u8, &self.bytes);
        self.len = 0;
    }
    pub fn password(self: *const Credentials) []const u8 {
        return self.bytes[0..self.len];
    }
};
