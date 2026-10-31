const std = @import("std");
const s = @import("spice");
const d = s.desktop_snapshot;
const t = std.testing;
const a = t.allocator;
fn snapshot(store: *s.surface.Store, token: *s.cancel.Token, generation: u64, sequence: u64, x: i64) !d.Snapshot {
    const revision = (try store.fill(0, &.{.{ .x = x, .y = 1, .width = 1, .height = 1 }}, @intCast(sequence), token)).?;
    const publication = (try store.publicationSnapshot(revision)).?;
    publication.commit();
    return .{ .stamp = .{ .generation = generation, .sequence = sequence }, .frame = .{ .publication = publication, .channel = 0, .damage = publication.damage(), .sequence = sequence } };
}
test "snapshot merges reordered damage while preserving newest cursor frame sequence and lifetime" {
    var store = s.surface.Store.init(a, .{}, null);
    var store_alive = true;
    defer if (store_alive) store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try store.create(0, 10, 10, 32, &token);
    const initial = try snapshot(&store, &token, 1, 1, 0);
    defer initial.deinit();
    const older = try snapshot(&store, &token, 1, 2, 1);
    defer older.deinit();
    var newer = try snapshot(&store, &token, 1, 3, 2);
    defer newer.deinit();
    newer.pointer = .relative;
    const merged = d.Snapshot.merge(newer, older);
    defer merged.deinit();
    try t.expectEqual(@as(u64, 3), merged.stamp.sequence);
    try t.expectEqual(@as(u64, 3), merged.frame.?.sequence);
    try t.expectEqual(.relative, merged.pointer);
    try t.expectEqual(@as(usize, 1), merged.frame.?.damage.count);
    try t.expectEqual(@as(i64, 2), merged.frame.?.damage.rectangles[0].width);
    var cursor_only = newer.clone();
    defer cursor_only.deinit();
    cursor_only.stamp.sequence = 4;
    cursor_only.frame.?.damage.clear();
    cursor_only.cursor = .{ .visible = true, .position = .{ .x = 12, .y = 13 } };
    const cursor_merged = d.Snapshot.merge(merged, cursor_only);
    defer cursor_merged.deinit();
    try t.expectEqual(@as(i16, 12), cursor_merged.cursor.?.position.x);
    try t.expectEqual(@as(u64, 3), cursor_merged.frame.?.sequence);
    try t.expectEqual(@as(i64, 2), cursor_merged.frame.?.damage.rectangles[0].width);
    store.deinit();
    store_alive = false;
    const bytes = try cursor_merged.frame.?.publication.pixels();
    try t.expectEqual(@as(u32, 0xff000003), std.mem.readInt(u32, bytes[(1 * 10 + 2) * 4 ..][0..4], .little));
}
test "surface recreation generation replacement and deletion cannot resurrect old frame" {
    var store = s.surface.Store.init(a, .{}, null);
    defer store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try store.create(0, 10, 10, 32, &token);
    const old = try snapshot(&store, &token, 1, 1, 0);
    defer old.deinit();
    try store.destroy(0, &token);
    try store.create(0, 10, 10, 32, &token);
    const recreated = try snapshot(&store, &token, 1, 2, 0);
    defer recreated.deinit();
    var empty_damage = recreated.clone();
    defer empty_damage.deinit();
    empty_damage.frame.?.damage.clear();
    const merged = d.Snapshot.merge(old, empty_damage);
    defer merged.deinit();
    try t.expect(merged.frame.?.damage.isFull());
    empty_damage.stamp.generation = 2;
    const migrated = d.Snapshot.merge(recreated, empty_damage);
    defer migrated.deinit();
    try t.expect(migrated.frame.?.damage.isFull());
    const deleted: d.Snapshot = .{ .stamp = .{ .generation = 2, .sequence = 3 } };
    const result = d.Snapshot.merge(deleted, recreated);
    defer result.deinit();
    try t.expect(result.frame == null);
}
test "ready latch keeps watermark through take discard restore and timestamps latest accepted update" {
    var latch: d.ReadyLatch = .{};
    defer latch.deinit();
    const first: d.Snapshot = .{ .stamp = .{ .generation = 1, .sequence = 2 } };
    const next: d.Snapshot = .{ .stamp = .{ .generation = 1, .sequence = 3 }, .pointer = .relative };
    try t.expect(latch.offer(first, 100));
    try t.expect(!latch.offer(next, 120));
    try t.expect(!latch.offer(first, 130));
    const selected = latch.take(150).?;
    defer selected.deinit();
    try t.expectEqual(@as(u64, 30), selected.waiting_ns);
    try t.expectEqual(@as(u64, 120), selected.ready_ns);
    try t.expectEqual(.relative, selected.snapshot.pointer);
    try t.expect(!latch.offer(next, 160));
    try t.expect(!latch.restoreIfEmpty(first, 100));
    try t.expect(latch.restoreIfEmpty(next, 120));
    const early = latch.take(110).?;
    defer early.deinit();
    try t.expectEqual(@as(u64, 0), early.waiting_ns);
    const fresh: d.Snapshot = .{ .stamp = .{ .generation = 2, .sequence = 0 } };
    try t.expect(latch.offer(fresh, 200));
    try t.expect(!latch.restoreIfEmpty(next, 120));
    latch.discard();
    try t.expect(!latch.offer(fresh, 210));
    try t.expect(latch.isEmpty());
}
fn offerMany(latch: *d.ReadyLatch, base: u64) void {
    for (1..1001) |i| _ = latch.offer(.{ .stamp = .{ .generation = base, .sequence = i } }, i);
}
test "ready latch concurrent producers cannot overwrite newest epoch" {
    var latch: d.ReadyLatch = .{};
    defer latch.deinit();
    const one = try std.Thread.spawn(.{}, offerMany, .{ &latch, 1 });
    defer one.join();
    const two = try std.Thread.spawn(.{}, offerMany, .{ &latch, 2 });
    two.join();
    const selected = latch.take(2000).?;
    defer selected.deinit();
    try t.expectEqual(@as(u64, 2), selected.snapshot.stamp.generation);
    try t.expectEqual(@as(u64, 1000), selected.snapshot.stamp.sequence);
}
