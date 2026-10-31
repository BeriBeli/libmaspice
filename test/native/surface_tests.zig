const std = @import("std");
const t = std.testing;
const s = @import("spice");
const a = t.allocator;
const Rect = s.region.Rect;
fn pixels(snapshot: s.surface.Snapshot, alloc: std.mem.Allocator) ![]u8 {
    const result = try alloc.alloc(u8, snapshot.width * snapshot.height * 4);
    errdefer alloc.free(result);
    const read = try snapshot.backing.read();
    defer read.finish() catch {};
    for (0..snapshot.height) |y| @memcpy(result[y * snapshot.width * 4 ..][0 .. snapshot.width * 4], read.bytes[y * read.stride ..][0 .. snapshot.width * 4]);
    return result;
}
fn transactions(alloc: std.mem.Allocator) !void {
    var store = s.surface.Store.init(alloc, .{}, null);
    defer store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try store.create(1, 4, 3, 32, &token);
    const original = try store.snapshot(1);
    defer original.deinit();
    const all: Rect = .{ .x = 0, .y = 0, .width = 4, .height = 3 };
    const first = (try store.fill(1, &.{all}, 0x12345678, &token)).?;
    try t.expectEqual(@as(u64, 1), first.value);
    const image = try s.image.Image.create(alloc, 4, 3, false, .straight);
    defer image.release();
    for (0..12) |i| {
        std.mem.writeInt(u32, image.unpublishedPixels()[i * 4 ..][0..4], @intCast(i + 1), .little);
    }
    _ = try store.copyImage(1, &.{all}, all, all, image, &token);
    const before = try store.snapshot(1);
    defer before.deinit();
    const destination: Rect = .{ .x = 1, .y = 1, .width = 3, .height = 2 };
    const source: Rect = .{ .x = 0, .y = 0, .width = 3, .height = 2 };
    // Deliberately unordered overlapping clips still read the immutable source.
    _ = try store.copyBits(1, &.{ .{ .x = 2, .y = 2, .width = 2, .height = 1 }, .{ .x = 1, .y = 1, .width = 3, .height = 2 } }, destination, source, &token);
    const after = try store.snapshot(1);
    defer after.deinit();
    const b = try pixels(before, alloc);
    defer alloc.free(b);
    const result = try pixels(after, alloc);
    defer alloc.free(result);
    for (0..3) |y| {
        for (0..4) |x| {
            const src = if (x >= 1 and y >= 1) (y - 1) * 4 + x - 1 else y * 4 + x;
            try t.expectEqualSlices(u8, b[src * 4 ..][0..4], result[(y * 4 + x) * 4 ..][0..4]);
        }
    }
    const zero = try pixels(original, alloc);
    defer alloc.free(zero);
    for (zero) |value| try t.expectEqual(@as(u8, 0), value);
    try store.destroy(1, &token);
    try store.create(1, 4, 3, 96, &token);
    const recreated = try store.snapshot(1);
    defer recreated.deinit();
    try t.expect(recreated.revision.lifecycle > after.revision.lifecycle);
    const retained = try pixels(after, alloc);
    defer alloc.free(retained);
    try t.expectEqualSlices(u8, result, retained);
}
test "Surface immutable revisions bottom-up alpha and overlap remain exact after recreate" {
    try transactions(a);
}
test "Surface allocation failures leave no leaked backing and no partial publication" {
    try t.checkAllAllocationFailures(a, transactions, .{});
}
test "Surface invalid geometry and cancellation preserve published revision pixels and damage" {
    var store = s.surface.Store.init(a, .{ .total_bytes = 16 }, null);
    defer store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try store.create(0, 2, 2, 32, &token);
    try t.expectError(error.SurfaceBudgetExceeded, store.create(1, 1, 1, 32, &token));
    const original = try store.snapshot(0);
    defer original.deinit();
    try t.expectError(error.InvalidRectangle, store.fill(0, &.{.{ .x = 0, .y = 0, .width = 3, .height = 2 }}, 0, &token));
    token.cancel();
    try t.expectError(error.Cancelled, store.fill(0, &.{.{ .x = 0, .y = 0, .width = 2, .height = 2 }}, 0, &token));
    const current = try store.snapshot(0);
    defer current.deinit();
    try t.expectEqual(original.revision, current.revision);
    const bytes = try pixels(current, a);
    defer a.free(bytes);
    for (bytes) |value| try t.expectEqual(@as(u8, 0), value);
    store.acknowledgeDamage(current.revision);
    const clean = try store.snapshot(0);
    defer clean.deinit();
    try t.expect(clean.damage == null);
}

fn sharedCanonicalBudget(alloc: std.mem.Allocator) !void {
    var budget: s.surface.MemoryBudget = .{ .maximum = 32 };
    defer budget.deinit();
    var first = s.surface.Store.init(alloc, .{}, null);
    first.shared_budget = &budget;
    defer first.deinit();
    var second = s.surface.Store.init(alloc, .{}, null);
    second.shared_budget = &budget;
    defer second.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try first.create(1, 2, 2, 32, &token);
    try second.create(1, 2, 2, 32, &token);
    try t.expectEqual(@as(usize, 32), budget.allocated());
    try t.expectError(error.SurfaceBudgetExceeded, first.create(2, 1, 1, 32, &token));
    const retained = try first.snapshot(1);
    defer retained.deinit();
    try first.destroy(1, &token);
    try t.expectEqual(@as(usize, 16), budget.allocated());
    try second.create(2, 2, 2, 32, &token);
    first.close();
    second.close();
    try t.expectEqual(@as(usize, 0), budget.allocated());
    const old = try retained.backing.read();
    defer old.finish() catch {};
    try t.expectEqual(@as(usize, 16), old.bytes.len);
}
test "canonical memory budget spans stores and unwinds every failed reservation" {
    try t.checkAllAllocationFailures(a, sharedCanonicalBudget, .{});
}
fn publicationDamage(alloc: std.mem.Allocator) !void {
    var store = s.surface.Store.init(alloc, .{}, null);
    var live = true;
    defer if (live) store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try store.create(1, 16, 4, 32, &token);
    const base = try store.snapshot(1);
    defer base.deinit();
    const initial = (try store.publicationSnapshot(base.revision)).?;
    defer initial.release();
    try t.expect(initial.damage().isFull());
    initial.commit();
    const r1 = Rect{ .x = 1, .y = 1, .width = 2, .height = 1 };
    const r2 = Rect{ .x = 8, .y = 2, .width = 3, .height = 1 };
    _ = try store.fill(1, &.{r1}, 0x112233, &token);
    const revision = (try store.fill(1, &.{r2}, 0x445566, &token)).?;
    try t.expect((try store.publicationSnapshot(.{ .id = 1, .lifecycle = revision.lifecycle, .value = revision.value + 1 })) == null);
    const prepared = (try store.publicationSnapshot(revision)).?;
    defer prepared.release();
    const damage = prepared.damage();
    try t.expect(!damage.isFull());
    try t.expectEqualSlices(Rect, &.{ r1, r2 }, damage.rectangles[0..damage.count]);
    const clean = (try store.publicationSnapshot(revision)).?;
    defer clean.release();
    try t.expect(clean.damage().isEmpty());
    clean.commit();
    const duplicate = prepared.retain();
    duplicate.restore();
    duplicate.restore();
    duplicate.release();
    const restored = (try store.publicationSnapshot(revision)).?;
    defer restored.release();
    try t.expectEqual(@as(usize, 2), restored.damage().count);
    restored.commit();
    restored.restore();
    const clean_again = (try store.publicationSnapshot(revision)).?;
    defer clean_again.release();
    try t.expect(clean_again.damage().isEmpty());
    // Pending lease belongs to its lifecycle, not a reusable surface ID.
    const newer = (try store.fill(1, &.{r1}, 0xff0000, &token)).?;
    const old = (try store.publicationSnapshot(newer)).?;
    defer old.release();
    try store.destroy(1, &token);
    try store.create(1, 2, 2, 32, &token);
    const recreated = try store.snapshot(1);
    defer recreated.deinit();
    const full = (try store.publicationSnapshot(recreated.revision)).?;
    defer full.release();
    full.commit();
    old.restore();
    const fresh = (try store.publicationSnapshot(recreated.revision)).?;
    defer fresh.release();
    try t.expect(fresh.damage().isEmpty());
    const metrics = store.metrics();
    try t.expectEqual(@as(u64, 3), metrics.damage_operations);
    try t.expectEqual(@as(u64, 28), metrics.damage_bytes);
    try t.expectEqual(@as(u64, 768), metrics.full_copy_bytes);
    try t.expectEqual(@as(u64, 0), metrics.cpu_materializations);
    try t.expectEqual(@as(usize, 8), metrics.publications);
    store.deinit();
    live = false;
    const old_pixels = try old.snapshot().backing.read();
    defer old_pixels.finish() catch {};
    try t.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, old_pixels.bytes[(16 + 1) * 4 ..][0..4]);
}
test "publication damage transfers once restores discarded frames and survives Store destruction" {
    try t.checkAllAllocationFailures(a, publicationDamage, .{});
}
test "damage keeps sparse L shapes and merges only lossless spans; 65 rectangles degrade to full" {
    var journal = try s.damage.Journal.init(10, 10, false);
    try journal.append(.{ .x = 0, .y = 0, .width = 10, .height = 1 });
    try journal.append(.{ .x = 0, .y = 0, .width = 1, .height = 10 });
    try t.expect(!journal.isFull());
    try t.expectEqual(@as(usize, 2), journal.count);
    try journal.append(.{ .x = 0, .y = 1, .width = 10, .height = 4 });
    try t.expect(journal.isFull());
    journal = try s.damage.Journal.init(200, 1, false);
    for (0..64) |i| try journal.append(.{ .x = @intCast(i * 2), .y = 0, .width = 1, .height = 1 });
    try t.expect(!journal.isFull());
    try journal.append(.{ .x = 128, .y = 0, .width = 1, .height = 1 });
    try t.expect(journal.isFull());
}
