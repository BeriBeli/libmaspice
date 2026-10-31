//! Complete ordered virt-viewer X.509 subject matching. No CN-only fallback.
const std = @import("std");
const wire = @import("bytes.zig");
const E = error{InvalidSubject};
const Value = struct { tag: u8, content: []const u8 };
fn der(r: *wire.Reader) E!Value {
    const tag = r.read(u8) catch return error.InvalidSubject;
    if (tag & 31 == 31) return error.InvalidSubject;
    const first = r.read(u8) catch return error.InvalidSubject;
    var size: usize = first;
    if (first & 128 != 0) {
        const count = first & 127;
        if (count == 0 or count > @sizeOf(isize)) return error.InvalidSubject;
        const bytes = r.take(count) catch return error.InvalidSubject;
        if (bytes[0] == 0) return error.InvalidSubject;
        size = 0;
        for (bytes) |byte| {
            if (size > @as(usize, std.math.maxInt(isize)) >> 8) return error.InvalidSubject;
            size = (size << 8) | byte;
        }
        if (size < 128) return error.InvalidSubject;
    }
    return .{ .tag = tag, .content = r.take(size) catch return error.InvalidSubject };
}
fn tagged(r: *wire.Reader, tag: u8) E![]const u8 {
    const value = try der(r);
    if (value.tag != tag) return error.InvalidSubject;
    return value.content;
}
const OID = struct {
    arcs: [32]u64 = undefined,
    len: usize = 0,
    fn add(self: *OID, value: u64) E!void {
        if (self.len == self.arcs.len) return error.InvalidSubject;
        self.arcs[self.len] = value;
        self.len += 1;
    }
};
fn decodeOID(bytes: []const u8) E!OID {
    if (bytes.len == 0) return error.InvalidSubject;
    var result: OID = .{};
    var value: u64 = 0;
    var continuation = false;
    for (bytes) |byte| {
        if (value > std.math.maxInt(u64) >> 7) return error.InvalidSubject;
        value = (value << 7) | (byte & 127);
        continuation = byte & 128 != 0;
        if (!continuation) {
            if (result.len == 0) {
                try result.add(if (value < 40) 0 else if (value < 80) 1 else 2);
                try result.add(if (value < 40) value else if (value < 80) value - 40 else value - 80);
            } else try result.add(value);
            value = 0;
        }
    }
    if (continuation) return error.InvalidSubject;
    return result;
}
fn expectedOID(key: []const u8) E!OID {
    const aliases = .{
        .{ "c", "2.5.4.6" },                        .{ "countryname", "2.5.4.6" },               .{ "st", "2.5.4.8" },                                 .{ "stateorprovincename", "2.5.4.8" },
        .{ "l", "2.5.4.7" },                        .{ "localityname", "2.5.4.7" },              .{ "street", "2.5.4.9" },                             .{ "streetaddress", "2.5.4.9" },
        .{ "o", "2.5.4.10" },                       .{ "organizationname", "2.5.4.10" },         .{ "ou", "2.5.4.11" },                                .{ "organizationalunitname", "2.5.4.11" },
        .{ "cn", "2.5.4.3" },                       .{ "commonname", "2.5.4.3" },                .{ "serialnumber", "2.5.4.5" },                       .{ "title", "2.5.4.12" },
        .{ "description", "2.5.4.13" },             .{ "postalcode", "2.5.4.17" },               .{ "givenname", "2.5.4.42" },                         .{ "sn", "2.5.4.4" },
        .{ "surname", "2.5.4.4" },                  .{ "initials", "2.5.4.43" },                 .{ "generationqualifier", "2.5.4.44" },               .{ "dnqualifier", "2.5.4.46" },
        .{ "pseudonym", "2.5.4.65" },               .{ "dc", "0.9.2342.19200300.100.1.25" },     .{ "domaincomponent", "0.9.2342.19200300.100.1.25" }, .{ "uid", "0.9.2342.19200300.100.1.1" },
        .{ "userid", "0.9.2342.19200300.100.1.1" }, .{ "emailaddress", "1.2.840.113549.1.9.1" },
    };
    var numeric = key;
    inline for (aliases) |alias| {
        if (std.ascii.eqlIgnoreCase(key, alias[0])) numeric = alias[1];
    }
    var parts = std.mem.splitScalar(u8, numeric, '.');
    var result: OID = .{};
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidSubject;
        try result.add(std.fmt.parseInt(u64, part, 10) catch return error.InvalidSubject);
    }
    if (result.len < 2 or result.arcs[0] > 2 or (result.arcs[0] != 2 and result.arcs[1] > 39)) return error.InvalidSubject;
    return result;
}
fn canonical(bytes: []const u8, buffer: *[8192]u8) E![]const u8 {
    if (bytes.len > buffer.len or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidSubject;
    var count: usize = 0;
    var space = false;
    for (bytes) |byte| {
        if (byte == 32) {
            if (count != 0) space = true;
            continue;
        }
        if (space) {
            buffer[count] = 32;
            count += 1;
            space = false;
        }
        buffer[count] = std.ascii.toLower(byte);
        count += 1;
    }
    if (count == 0) return error.InvalidSubject;
    return buffer[0..count];
}
fn string(value: Value, output: *[8192]u8) E![]const u8 {
    if (value.content.len > 8192) return error.InvalidSubject;
    switch (value.tag) {
        0x0c => return value.content,
        0x12, 0x13, 0x16, 0x1a => {
            for (value.content) |byte| {
                if (byte > 127) return error.InvalidSubject;
            }
            return value.content;
        },
        0x14, 0x1c, 0x1e => {},
        else => return error.InvalidSubject,
    }
    var reader = wire.Reader.init(value.content, 0) catch unreachable;
    var count: usize = 0;
    while (reader.remaining() != 0) {
        var scalar: u32 = switch (value.tag) {
            0x14 => reader.read(u8) catch return error.InvalidSubject,
            0x1c => @byteSwap(reader.read(u32) catch return error.InvalidSubject),
            else => @byteSwap(reader.read(u16) catch return error.InvalidSubject),
        };
        if (value.tag == 0x1e and scalar >= 0xd800 and scalar <= 0xdbff) {
            const low = @byteSwap(reader.read(u16) catch return error.InvalidSubject);
            if (low < 0xdc00 or low > 0xdfff) return error.InvalidSubject;
            scalar = 0x10000 + ((scalar - 0xd800) << 10) + low - 0xdc00;
        }
        if (scalar > 0x10ffff or (scalar >= 0xd800 and scalar <= 0xdfff)) return error.InvalidSubject;
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(@intCast(scalar), &encoded) catch return error.InvalidSubject;
        if (length > output.len - count) return error.InvalidSubject;
        @memcpy(output[count..][0..length], encoded[0..length]);
        count += length;
    }
    return output[0..count];
}

pub fn matches(expected: []const u8, actual: []const u8) bool {
    return match(expected, actual) catch false;
}
fn match(expected: []const u8, actual: []const u8) !bool {
    if (expected.len == 0 or expected.len > 16384 or actual.len > 16384 or !std.unicode.utf8ValidateSlice(expected)) return false;
    var outer = try wire.Reader.init(actual, 0);
    var name = try wire.Reader.init(try tagged(&outer, 0x30), 0);
    try outer.finish();
    var offset: usize = 0;
    var count: usize = 0;
    while (offset < expected.len) {
        while (offset < expected.len and expected[offset] == 32) offset += 1;
        if (offset == expected.len) break;
        var key: [8192]u8 = undefined;
        var text: [8192]u8 = undefined;
        var key_len: usize = 0;
        var text_len: usize = 0;
        var in_value = false;
        while (offset < expected.len) {
            var byte = expected[offset];
            offset += 1;
            if (byte == '\\') {
                if (offset == expected.len) return false;
                byte = expected[offset];
                offset += 1;
                if (byte != '\\' and byte != ',') return false;
            } else if (byte == ',') {
                if (!in_value) return false;
                break;
            } else if (byte == '=' and !in_value) {
                in_value = true;
                continue;
            }
            if (in_value) {
                if (text_len == text.len) return false;
                text[text_len] = byte;
                text_len += 1;
            } else {
                if (key_len == key.len) return false;
                key[key_len] = byte;
                key_len += 1;
            }
        }
        if (!in_value or key_len == 0 or count >= 128) return false;
        const expected_oid = try expectedOID(key[0..key_len]);
        var expected_buffer: [8192]u8 = undefined;
        const expected_value = try canonical(text[0..text_len], &expected_buffer);
        var rdn = try wire.Reader.init(try tagged(&name, 0x31), 0);
        var attribute = try wire.Reader.init(try tagged(&rdn, 0x30), 0);
        try rdn.finish(); // Exactly one attribute, preserving RDN grouping.
        const actual_oid = try decodeOID(try tagged(&attribute, 0x06));
        const value = try der(&attribute);
        try attribute.finish();
        var decoded: [8192]u8 = undefined;
        var actual_buffer: [8192]u8 = undefined;
        const actual_value = try canonical(try string(value, &decoded), &actual_buffer);
        if (!std.mem.eql(u64, expected_oid.arcs[0..expected_oid.len], actual_oid.arcs[0..actual_oid.len]) or
            !std.mem.eql(u8, expected_value, actual_value)) return false;
        count += 1;
    }
    return count != 0 and name.remaining() == 0;
}
