//! SPICE ticket policy/DER handling in Zig; Apple Security performs RSA-OAEP.
const std = @import("std");
const wire = @import("bytes.zig");
extern fn spice_zig_security_encrypt(key: [*]const u8, key_size: usize, plaintext: [*]const u8, plaintext_size: usize, output: *[128]u8) c_int;

pub const Error = error{ PasswordTooLong, PasswordContainsNUL, InvalidPublicKey, UnsupportedPublicKey, EncryptionFailed };

fn derValue(reader: *wire.Reader, tag: u8) Error![]const u8 {
    if ((reader.read(u8) catch return error.InvalidPublicKey) != tag) return error.InvalidPublicKey;
    const first = reader.read(u8) catch return error.InvalidPublicKey;
    var length: usize = first;
    if (first & 0x80 != 0) {
        const count = first & 0x7f;
        if (count == 0 or count > @sizeOf(usize)) return error.InvalidPublicKey;
        const encoded = reader.take(count) catch return error.InvalidPublicKey;
        length = 0;
        for (encoded) |byte| {
            length = std.math.mul(usize, length, 256) catch return error.InvalidPublicKey;
            length = std.math.add(usize, length, byte) catch return error.InvalidPublicKey;
        }
    }
    return reader.take(length) catch return error.InvalidPublicKey;
}

pub fn pkcs1(der: []const u8) Error![]const u8 {
    var outer = wire.Reader.init(der, 0) catch unreachable;
    const sequence = try derValue(&outer, 0x30);
    outer.finish() catch return error.InvalidPublicKey;
    if (sequence.len == 0) return error.InvalidPublicKey;
    if (sequence[0] == 0x02) return der;
    var inner = wire.Reader.init(sequence, 0) catch unreachable;
    _ = try derValue(&inner, 0x30);
    const bits = try derValue(&inner, 0x03);
    inner.finish() catch return error.InvalidPublicKey;
    if (bits.len == 0 or bits[0] != 0) return error.InvalidPublicKey;
    return bits[1..];
}

pub fn encrypt(password: []const u8, public_key: []const u8) Error![128]u8 {
    if (password.len > 60) return error.PasswordTooLong;
    if (std.mem.indexOfScalar(u8, password, 0) != null) return error.PasswordContainsNUL;
    const key = try pkcs1(public_key);
    var plaintext: [61]u8 = @splat(0);
    defer std.crypto.secureZero(u8, &plaintext);
    @memcpy(plaintext[0..password.len], password);
    var output: [128]u8 = undefined;
    switch (spice_zig_security_encrypt(key.ptr, key.len, &plaintext, password.len + 1, &output)) {
        0 => return output,
        1 => return error.UnsupportedPublicKey,
        else => return error.EncryptionFailed,
    }
}

test "password policy precedes key parsing; bounded DER truncation and overflow" {
    const t = std.testing;
    try t.expectError(error.PasswordTooLong, encrypt(&@as([61]u8, @splat(1)), &.{}));
    try t.expectError(error.PasswordContainsNUL, encrypt(&.{ 1, 0, 2 }, &.{}));
    const spki = [_]u8{ 0x30, 8, 0x30, 0, 0x03, 4, 0, 0x30, 1, 2 };
    try t.expectEqualSlices(u8, &.{ 0x30, 1, 2 }, try pkcs1(&spki));
    for (0..spki.len) |length| try t.expectError(error.InvalidPublicKey, pkcs1(spki[0..length]));
    try t.expectError(error.InvalidPublicKey, pkcs1(&.{ 0x30, 0x80 }));
    try t.expectError(error.InvalidPublicKey, pkcs1(&.{ 0x30, 0x88, 255, 255, 255, 255, 255, 255, 255, 255 }));
    try t.expectError(error.InvalidPublicKey, pkcs1(&(spki ++ [_]u8{0})));
}

pub export fn spice_zig_ticket_encrypt(password: ?[*]const u8, password_size: usize, key: ?[*]const u8, key_size: usize, output: ?*[128]u8) c_int {
    const out = output orelse return -1;
    if ((password == null and password_size != 0) or key == null) return -1;
    const pass = if (password) |p| p[0..password_size] else &.{};
    const result = encrypt(pass, key.?[0..key_size]) catch |err| return switch (err) {
        error.PasswordTooLong => -10,
        error.PasswordContainsNUL => -11,
        error.InvalidPublicKey => -12,
        error.UnsupportedPublicKey => -13,
        error.EncryptionFailed => -14,
    };
    out.* = result;
    return 0;
}
