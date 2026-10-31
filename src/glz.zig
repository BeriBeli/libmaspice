//! GLZ parse/snapshot/execute/commit. Parse completes before dictionary waits;
//! failed decode/commit cannot evict entries or publish a partial image. The
//! dictionary mutex protects coordination only, never pixel copying/admission.
const std = @import("std");
const wire = @import("bytes.zig");
const sync = @import("sync.zig");
const cancel = @import("cancel.zig");
const images = @import("image.zig");
const executor = @import("codec_executor.zig");
pub const Limits = struct { dimension: usize = 16384, encoded: usize = 64 * 1024 * 1024, decoded: usize = 256 * 1024 * 1024, dictionary_images: usize = 256 * 1024, dictionary_bytes: usize = 256 * 1024 * 1024, waits: usize = 64, operations: usize = 1048576 };
const Plane = enum {
    color,
    rgb16,
    alpha,
    fn literalBytes(self: Plane) usize {
        return switch (self) {
            .color => 3,
            .rgb16 => 2,
            .alpha => 1,
        };
    }
    fn bias(self: Plane) usize {
        return switch (self) {
            .color => 0,
            .rgb16 => 1,
            .alpha => 2,
        };
    }
};
const Operation = struct { kind: enum { literal, current, dictionary }, plane: Plane, source: usize, destination: usize, count: usize, id: u64 = 0 };
pub const Program = struct {
    allocator: std.mem.Allocator,
    payload: []const u8,
    width: usize,
    height: usize,
    top_down: bool,
    alpha: bool,
    id: u64,
    window: u32,
    output_bytes: usize,
    retained_bytes: usize,
    operations: std.ArrayList(Operation) = .empty,
    dependencies: std.ArrayList(u64) = .empty,
    pub fn deinit(self: *Program) void {
        self.operations.deinit(self.allocator);
        self.dependencies.deinit(self.allocator);
    }
};
fn be(reader: *wire.Reader, comptime T: type) !T {
    return @byteSwap(try reader.read(T));
}
pub fn parse(a: std.mem.Allocator, payload: []const u8, width: usize, height: usize, limits: Limits) !Program {
    if (payload.len == 0) return error.EmptyPayload;
    if (payload.len > limits.encoded) return error.EncodedImageTooLarge;
    var reader = try wire.Reader.init(payload, 0);
    if (try be(&reader, u32) != 0x20205a4c or try be(&reader, u32) != 0x00010001) return error.InvalidHeader;
    const flags = try reader.read(u8);
    if (flags & 0xe0 != 0) return error.InvalidHeader;
    const kind = flags & 0xf;
    if (kind < 6 or kind > 9) return error.UnsupportedFormat;
    const w = try be(&reader, u32);
    const h = try be(&reader, u32);
    const stride = try be(&reader, u32);
    const id = try be(&reader, u64);
    const window = try be(&reader, u32);
    if (w == 0 or h == 0 or w > limits.dimension or h > limits.dimension) return error.InvalidDimensions;
    if (w != width or h != height) return error.DimensionMismatch;
    if (stride != try std.math.mul(usize, width, if (kind == 6) 2 else if (kind == 7) 3 else 4) or window > id) return error.InvalidHeader;
    const count = try std.math.mul(usize, width, height);
    const size = try std.math.mul(usize, count, 4);
    if (size > limits.decoded) return error.DecodedImageTooLarge;
    var program: Program = .{ .allocator = a, .payload = payload, .width = width, .height = height, .top_down = flags & 0x10 != 0, .alpha = kind == 9, .id = id, .window = window, .output_bytes = size, .retained_bytes = 0 };
    errdefer program.deinit();
    var dependencies: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer dependencies.deinit(a);
    try parsePlane(&program, &reader, &dependencies, if (kind == 6) .rgb16 else .color, count, limits.operations);
    if (kind == 9) try parsePlane(&program, &reader, &dependencies, .alpha, count, limits.operations);
    try reader.finish();
    try program.dependencies.ensureTotalCapacity(a, dependencies.count());
    var iter = dependencies.keyIterator();
    while (iter.next()) |key| program.dependencies.appendAssumeCapacity(key.*);
    std.mem.sort(u64, program.dependencies.items, {}, std.sort.asc(u64));
    // Charge capacity plus conservative metadata; retained owner is charged by
    // decode separately, and each captured dependency is charged before waiting.
    var retained = try std.math.add(usize, size, payload.len);
    retained = try std.math.add(usize, retained, try std.math.mul(usize, program.operations.capacity, @sizeOf(Operation)));
    retained = try std.math.add(usize, retained, try std.math.mul(usize, program.dependencies.capacity, @sizeOf(u64)));
    program.retained_bytes = try std.math.add(usize, retained, 1280);
    return program;
}
fn parsePlane(program: *Program, reader: *wire.Reader, dependencies: *std.AutoHashMapUnmanaged(u64, void), plane: Plane, count: usize, maximum: usize) !void {
    var destination: usize = 0;
    while (destination < count) {
        if (program.operations.items.len >= maximum) return error.ProgramLimitExceeded;
        const control = try reader.read(u8);
        var operation: Operation = undefined;
        if (control < 32) {
            const length = @as(usize, control) + 1;
            if (length > count - destination) return error.MalformedPayload;
            const source = reader.offset;
            _ = try reader.take(length * plane.literalBytes());
            operation = .{ .kind = .literal, .plane = plane, .source = source, .destination = destination, .count = length };
        } else {
            var length: usize = control >> 5;
            if (length == 7) {
                while (true) {
                    const extra = try reader.read(u8);
                    length = try std.math.add(usize, length, extra);
                    if (extra != 255) break;
                }
            }
            var offset: usize = control & 15;
            offset += @as(usize, try reader.read(u8)) << 4;
            const code = try reader.read(u8);
            const distance_bytes = code >> 6;
            var distance: u64 = 0;
            if (control & 16 == 0) {
                distance = code & 63;
                for (0..distance_bytes) |i| distance += @as(u64, try reader.read(u8)) << @intCast(6 + 8 * i);
            } else {
                offset += @as(usize, code & 31) << 12;
                for (0..distance_bytes) |i| distance += @as(u64, try reader.read(u8)) << @intCast(8 * i);
                if (code & 32 != 0) offset += @as(usize, try reader.read(u8)) << 17;
            }
            length = try std.math.add(usize, length, plane.bias());
            if (length > count - destination) return error.MalformedPayload;
            if (distance == 0) {
                offset += 1;
                if (offset > destination) return error.MalformedPayload;
                operation = .{ .kind = .current, .plane = plane, .source = destination - offset, .destination = destination, .count = length };
            } else {
                if (distance > program.id) return error.MalformedPayload;
                const id = program.id - distance;
                try dependencies.put(program.allocator, id, {});
                operation = .{ .kind = .dictionary, .plane = plane, .source = offset, .destination = destination, .count = length, .id = id };
            }
        }
        try program.operations.append(program.allocator, operation);
        destination += operation.count;
    }
}
const Entry = struct { image: images.Image, window: u32 };
const Dependency = struct { id: u64, image: images.Image };
pub const Diagnostics = struct { generation: u64, images: usize, bytes: usize, reservations: usize, waits: usize, wait_bytes: usize };
pub const Decoder = struct {
    const Waiter = struct { next: ?*Waiter = null, id: u64, bytes: usize, result: ?images.Image = null, failure: ?anyerror = null, done: bool = false };
    allocator: std.mem.Allocator,
    limits: Limits = .{},
    executor: *executor.Executor,
    mutex: sync.Mutex = .{},
    changed: sync.Condition = .{},
    generation: u64 = 0,
    closed: bool = false,
    oldest: u64 = 0,
    tail_gap: u64 = 0,
    dictionary_bytes: usize = 0,
    dictionary: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    reservations: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    head: ?*Waiter = null,
    wait_count: usize = 0,
    wait_bytes: usize = 0,
    pub fn init(a: std.mem.Allocator, pool: *executor.Executor, limits: Limits) Decoder {
        return .{ .allocator = a, .executor = pool, .limits = limits };
    }
    fn wake(p: *anyopaque) void {
        const self: *Decoder = @ptrCast(@alignCast(p));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.changed.broadcast();
    }
    pub fn diagnostics(self: *Decoder) Diagnostics {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .generation = self.generation, .images = self.dictionary.count(), .bytes = self.dictionary_bytes, .reservations = self.reservations.count(), .waits = self.wait_count, .wait_bytes = self.wait_bytes };
    }
    pub fn clear(self: *Decoder) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.generation = try std.math.add(u64, self.generation, 1);
        self.reset();
    }
    fn reset(self: *Decoder) void {
        var iter = self.dictionary.valueIterator();
        while (iter.next()) |entry| entry.image.release();
        self.dictionary.clearRetainingCapacity();
        self.reservations.clearRetainingCapacity();
        self.dictionary_bytes = 0;
        self.oldest = 0;
        self.tail_gap = 0;
        var waiter = self.head;
        while (waiter) |item| : (waiter = item.next) {
            if (!item.done) self.resolve(item, null, error.Cancelled);
        }
        self.changed.broadcast();
    }
    pub fn close(self: *Decoder) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.reset();
    }
    /// All decode callers must be joined before deinit.
    pub fn deinit(self: *Decoder) void {
        self.close();
        std.debug.assert(self.head == null);
        self.dictionary.deinit(self.allocator);
        self.reservations.deinit(self.allocator);
        self.changed.deinit();
        self.mutex.deinit();
    }
    fn resolve(self: *Decoder, waiter: *Waiter, result: ?images.Image, failure: ?anyerror) void {
        std.debug.assert(!waiter.done);
        waiter.done = true;
        waiter.result = result;
        waiter.failure = failure;
        self.wait_count -= 1;
        self.wait_bytes -= waiter.bytes;
    }
    fn lookup(self: *Decoder, id: u64, retained: usize, generation: u64, token: *cancel.Token) !images.Image {
        var registration: cancel.Registration = .{ .context = self, .wake = wake };
        token.register(&registration);
        defer token.unregister(&registration);
        self.mutex.lock();
        defer self.mutex.unlock();
        try token.check();
        if (self.closed or self.generation != generation) return error.Cancelled;
        if (self.dictionary.get(id)) |entry| return entry.image.retain();
        if (id < self.oldest) return error.DictionaryImageEvicted;
        if (self.wait_count >= self.limits.waits) return error.DictionaryWaitLimit;
        if (retained > self.limits.dictionary_bytes - self.wait_bytes) return error.DictionaryWaitBytesExceeded;
        var waiter: Waiter = .{ .next = self.head, .id = id, .bytes = retained };
        self.head = &waiter;
        self.wait_count += 1;
        self.wait_bytes += retained;
        defer {
            var slot = &self.head;
            while (slot.*) |item| {
                if (item == &waiter) {
                    slot.* = item.next;
                    break;
                }
                slot = &item.next;
            }
            if (!waiter.done) self.resolve(&waiter, null, error.Cancelled);
        }
        while (!waiter.done) {
            try token.check();
            self.changed.wait(&self.mutex);
        }
        if (waiter.failure) |failure| return failure;
        return waiter.result.?;
    }
    pub fn decode(self: *Decoder, payload: []const u8, width: usize, height: usize, retained_owner: usize, token: *cancel.Token) !images.Image {
        try token.check();
        var program = try parse(self.allocator, payload, width, height, self.limits);
        defer program.deinit();
        var retained = try std.math.add(usize, program.retained_bytes, retained_owner);
        self.mutex.lock();
        const generation = self.generation;
        const reserve_result = self.reserve(program.id, generation);
        self.mutex.unlock();
        try reserve_result;
        defer {
            self.mutex.lock();
            if (self.reservations.get(program.id)) |g| {
                if (g == generation) _ = self.reservations.remove(program.id);
            }
            self.mutex.unlock();
        }
        var dependencies: std.ArrayList(Dependency) = .empty;
        defer {
            for (dependencies.items) |dependency| dependency.image.release();
            dependencies.deinit(self.allocator);
        }
        try dependencies.ensureTotalCapacity(self.allocator, program.dependencies.items.len);
        for (program.dependencies.items) |id| {
            const image = try self.lookup(id, retained, generation, token);
            dependencies.appendAssumeCapacity(.{ .id = id, .image = image });
            retained = try std.math.add(usize, retained, try std.math.add(usize, image.pixels().len, 128));
        }
        try self.executor.acquire(retained, token);
        defer self.executor.finish();
        const image = try execute(self.allocator, &program, dependencies.items, token);
        errdefer image.release();
        self.mutex.lock();
        defer self.mutex.unlock();
        try token.check();
        try self.commit(&program, generation, image);
        return image;
    }
    fn reserve(self: *Decoder, id: u64, generation: u64) !void {
        if (self.closed) return error.Cancelled;
        if (self.dictionary.contains(id) or self.reservations.contains(id)) return error.DuplicateImage;
        try self.reservations.put(self.allocator, id, generation);
    }
    fn commit(self: *Decoder, program: *const Program, generation: u64, image: images.Image) !void {
        if (self.closed or self.generation != generation or self.reservations.get(program.id) != generation) return error.Cancelled;
        if (self.dictionary.contains(program.id)) return error.DuplicateImage;
        var tail = self.tail_gap;
        while (tail == program.id or self.dictionary.contains(tail)) tail = try std.math.add(u64, tail, 1);
        var oldest = self.oldest;
        if (tail > 0) {
            const last = tail - 1;
            const window = if (last == program.id) program.window else if (self.dictionary.get(last)) |entry| entry.window else null;
            if (window) |w| oldest = @max(oldest, last - w);
        }
        var removed: usize = 0;
        var removed_bytes: usize = 0;
        var iterator = self.dictionary.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.* < oldest) {
                removed += 1;
                removed_bytes += entry.value_ptr.image.pixels().len;
            }
        }
        const stores = program.id >= oldest;
        const count = self.dictionary.count() + @as(usize, @intFromBool(stores)) - removed;
        if (count > self.limits.dictionary_images) return error.DictionaryImagesExceeded;
        const added = if (stores) image.pixels().len else 0;
        const bytes = try std.math.add(usize, self.dictionary_bytes - removed_bytes, added);
        if (bytes > self.limits.dictionary_bytes) return error.DictionaryBytesExceeded;
        // Reserve the sole fallible allocation before making any observable mutation.
        if (stores) try self.dictionary.ensureUnusedCapacity(self.allocator, 1);
        // Removing by iterator is supported by HashMap; entries already captured
        // by waiting decoders retain their own immutable reference.
        iterator = self.dictionary.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.* < oldest) {
                entry.value_ptr.image.release();
                const id = entry.key_ptr.*;
                _ = self.dictionary.remove(id);
            }
        }
        if (stores) self.dictionary.putAssumeCapacity(program.id, .{ .image = image.retain(), .window = program.window });
        _ = self.reservations.remove(program.id);
        self.oldest = oldest;
        self.tail_gap = tail;
        self.dictionary_bytes = bytes;
        var waiter = self.head;
        while (waiter) |item| : (waiter = item.next) {
            if (item.done) continue;
            if (stores and item.id == program.id) self.resolve(item, image.retain(), null) else if (item.id < oldest) self.resolve(item, null, error.DictionaryImageEvicted);
        }
        self.changed.broadcast();
    }
};
fn execute(a: std.mem.Allocator, program: *const Program, dependencies: []const Dependency, token: *cancel.Token) !images.Image {
    const image = try images.Image.create(a, program.width, program.height, program.top_down, if (program.alpha) .straight else .opaque_pixels);
    errdefer image.release();
    const output = image.unpublishedPixels();
    @memset(output, 0);
    for (program.operations.items) |operation| {
        try token.check();
        const destination = operation.destination * 4;
        if (operation.kind == .literal) {
            var source = operation.source;
            for (0..operation.count) |i| {
                const dst = destination + i * 4;
                switch (operation.plane) {
                    .color => {
                        @memcpy(output[dst..][0..3], program.payload[source..][0..3]);
                        source += 3;
                    },
                    .alpha => {
                        output[dst + 3] = program.payload[source];
                        source += 1;
                    },
                    .rgb16 => {
                        const r = program.payload[source];
                        const b = program.payload[source + 1];
                        source += 2;
                        var g = ((r << 6) | (b >> 2)) & 0xf8;
                        g |= g >> 5;
                        output[dst] = b << 3 | ((b >> 2) & 7);
                        output[dst + 1] = g;
                        output[dst + 2] = (r << 1 & 0xf8) | ((r >> 4) & 7);
                    },
                }
            }
            continue;
        }
        var source: []const u8 = output;
        if (operation.kind == .dictionary) {
            const index = std.sort.binarySearch(Dependency, dependencies, operation.id, struct {
                fn compare(id: u64, dep: Dependency) std.math.Order {
                    return std.math.order(id, dep.id);
                }
            }.compare) orelse return error.MissingDictionaryImage;
            source = dependencies[index].image.pixels();
            if (operation.source > source.len / 4 or operation.count > source.len / 4 - operation.source) return error.DictionaryReferenceOutOfBounds;
        }
        var copied: usize = 0;
        while (copied < operation.count) {
            const span = if (operation.kind == .current) @min(if (copied == 0) operation.destination - operation.source else copied, operation.count - copied) else operation.count - copied;
            const source_start = if (operation.kind == .current and copied != 0) operation.destination else operation.source + copied;
            var offset: usize = 0;
            while (offset < span) {
                try token.check();
                const count: usize = @min(@as(usize, 65536), span - offset);
                const src = (source_start + offset) * 4;
                const dst = destination + (copied + offset) * 4;
                if (operation.plane == .alpha) {
                    for (0..count) |i| output[dst + i * 4 + 3] = source[src + i * 4 + 3];
                } else @memcpy(output[dst..][0 .. count * 4], source[src..][0 .. count * 4]);
                offset += count;
            }
            copied += span;
        }
    }
    try token.check();
    return image;
}
