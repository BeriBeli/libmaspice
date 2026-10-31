// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2009 Red Hat, Inc.
// Codec/allocator ABI boundary. Fatal errors are returned to adapter.c, never
// invoked from Zig, so longjmp in the caller's error handler stays within C.
const std = @import("std");
const codec = @import("codec.zig");
const Allocator = std.mem.Allocator;

const User = extern struct {
    err: ?*const anyopaque,
    warn: ?*const anyopaque,
    info: ?*const anyopaque,
    malloc: *const fn (*User, c_int) callconv(.c) ?*anyopaque,
    free: *const fn (*User, ?*anyopaque) callconv(.c) void,
    more_space: *const fn (*User, *?[*]u8, c_int) callconv(.c) c_int,
    more_lines: *const fn (*User, *?[*]const u8) callconv(.c) c_int,
};

const State = struct {
    user: *User,
    codec: codec.Context,
};

fn allocate(pointer: *anyopaque, length: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const user: *User = @ptrCast(@alignCast(pointer));
    // All codec allocations have ordinary malloc alignment. Reject rather than
    // truncating the signed size in the upstream callback ABI.
    if (length > std.math.maxInt(c_int) or alignment.toByteUnits() > @alignOf(u128)) return null;
    const memory = user.malloc(user, @intCast(length)) orelse return null;
    return @ptrCast(memory);
}
fn release(pointer: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    const user: *User = @ptrCast(@alignCast(pointer));
    user.free(user, memory.ptr);
}
const vtable: Allocator.VTable = .{ .alloc = allocate, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = release };
fn allocator(user: *User) Allocator {
    return .{ .ptr = user, .vtable = &vtable };
}

fn moreInput(pointer: ?*anyopaque, output: *?[*]const u8, rows: c_int) callconv(.c) c_int {
    const user: *User = @ptrCast(@alignCast(pointer.?));
    var data: ?[*]u8 = null;
    const count = user.more_space(user, &data, rows);
    output.* = data;
    return count;
}
fn moreOutput(pointer: ?*anyopaque, output: *?[*]u8, rows: c_int) callconv(.c) c_int {
    const user: *User = @ptrCast(@alignCast(pointer.?));
    return user.more_space(user, output, rows);
}
fn moreLines(pointer: ?*anyopaque, output: *?[*]const u8) callconv(.c) c_int {
    const user: *User = @ptrCast(@alignCast(pointer.?));
    return user.more_lines(user, output);
}

fn failure(err: codec.DecodeError) c_int {
    return switch (err) {
        error.OutOfMemory => -3,
        error.Truncated, error.OutputExhausted, error.LinesExhausted, error.MalformedCode, error.InvalidRun, error.LimitExceeded => -2,
        else => -1,
    };
}

export fn spice_quic_zig_create(user: *User) ?*State {
    const state = allocator(user).create(State) catch return null;
    state.* = .{ .user = user, .codec = .{ .allocator = allocator(user) } };
    return state;
}
export fn spice_quic_zig_destroy(state: *State) void {
    allocator(state.user).destroy(state);
}
export fn spice_quic_zig_user(state: *State) *User {
    return state.user;
}

export fn spice_quic_zig_begin(state: *State, input: ?[*]const u8, words: c_uint, kind: *c_int, width: *c_int, height: *c_int) c_int {
    state.codec.reader = null;
    if (words == 0 or input == null) return -1;
    const metadata = state.codec.begin(input.?[0 .. @as(usize, words) * 4], moreInput, state.user) catch |err| {
        return if (err == error.UnsupportedType) -2 else failure(err);
    };
    kind.* = metadata.kind;
    width.* = metadata.width;
    height.* = metadata.height;
    return 0;
}

export fn spice_quic_zig_decode(state: *State, kind: c_int, output: ?[*]u8, stride: c_int) c_int {
    if (output == null or state.codec.reader == null) return -1;
    const width: usize = @intCast(state.codec.metadata.width);
    const height: usize = @intCast(state.codec.metadata.height);
    const pitch: usize = @intCast(@abs(@as(i64, stride)));
    const row = width * codec.components(kind);
    if (row == 0 or pitch < row) return -1;
    const tail = std.math.mul(usize, height - 1, pitch) catch return -1;
    const length = std.math.add(usize, tail, row) catch return -1;
    const start = if (stride < 0) std.math.sub(usize, @intFromPtr(output.?), tail) catch return -1 else @intFromPtr(output.?);
    const base: [*]u8 = @ptrFromInt(start);
    state.codec.finish(kind, base[0..length], stride) catch |err| return failure(err);
    return 0;
}

export fn spice_quic_zig_encode(state: *State, kind: c_int, width: c_int, height: c_int, input: ?[*]const u8, count: c_uint, stride: c_int, output: ?[*]u8, words: c_uint) c_int {
    state.codec.reader = null;
    if ((output == null and words != 0) or (input == null and count != 0)) return -1;
    var lines: codec.Lines = .{ .pointer = input, .count = count, .stride = stride, .more = moreLines, .user = state.user };
    var writer: codec.Writer = .{ .output = if (output) |p| p[0 .. @as(usize, words) * 4] else &.{}, .more = moreOutput, .user = state.user };
    return codec.encode(allocator(state.user), kind, width, height, &lines, &writer) catch |err| {
        return if (err == error.UnsupportedType) -2 else failure(err);
    };
}
