const std = @import("std");
const t = std.testing;
const s = @import("spice");
const q = s.webdav_queue;
const a = t.allocator;
const get = "GET / HTTP/1.1\r\n\r\n";
const put = "PUT /a HTTP/1.1\r\nContent-Length: 1\r\n\r\nx";
fn empty(queue: *q.Queue, job: *q.Job) !void {
    queue.filesystemDone(job, .{ .bytes = try a.dupe(u8, "ok") });
}
fn allocated(allocator: std.mem.Allocator) !void {
    var queue = try q.Queue.init(allocator, .{ .http = .{ .body_bytes = 32 } });
    defer queue.deinit();
    _ = try queue.submit(3, "GET ");
    _ = try queue.submit(3, "/ HTTP/1.1\r\n\r\n" ++ put);
    try t.expectEqual(2, queue.diagnostics().pending_jobs);
}
test "WebDAV batch allocation failure and malformed or oversized batch leave accepted input intact" {
    try t.checkAllAllocationFailures(a, allocated, .{});
    var queue = try q.Queue.init(a, .{ .jobs = 1, .http = .{ .body_bytes = 32 } });
    defer queue.deinit();
    try t.expect(!try queue.submit(3, "GET "));
    try t.expectError(error.TooManyPendingJobs, queue.submit(3, "/ HTTP/1.1\r\n\r\n" ++ put));
    try t.expectEqual(4, queue.diagnostics().buffered_bytes);
    try t.expectEqual(0, queue.diagnostics().pending_jobs);
    try t.expectError(error.InvalidRequest, queue.submit(3, "/ HTTP/9\r\n\r\n"));
    try t.expect(try queue.submit(3, "/ HTTP/1.1\r\n\r\n"));
    const job = queue.takeFilesystem().?;
    try t.expectEqual(1, job.request.sequence);
    try empty(&queue, job);
    const response = queue.takeResponse().?;
    queue.responseDone(response, true);
    try t.expectEqual(1, queue.diagnostics().completed);
    try t.expectEqual(0, queue.diagnostics().retained());
}
test "WebDAV independent clients advance while each client waits for its preceding response" {
    var queue = try q.Queue.init(a, .{ .http = .{ .body_bytes = 32 } });
    defer queue.deinit();
    _ = try queue.submit(1, get ++ put);
    _ = try queue.submit(2, get);
    const first = queue.takeFilesystem().?;
    const other = queue.takeFilesystem().?;
    try t.expectEqual(1, first.client);
    try t.expectEqual(2, other.client);
    try t.expectEqual(null, queue.takeFilesystem());
    try empty(&queue, first);
    try empty(&queue, other);
    const send_first = queue.takeResponse().?;
    const send_other = queue.takeResponse().?;
    try t.expectEqual(null, queue.takeFilesystem());
    queue.responseDone(send_other, true);
    try t.expectEqual(null, queue.takeFilesystem());
    queue.responseDone(send_first, true);
    const next = queue.takeFilesystem().?;
    try t.expectEqualStrings("PUT", next.request.method);
    try empty(&queue, next);
    queue.responseDone(queue.takeResponse().?, true);
    try t.expectEqual(3, queue.diagnostics().completed);
}
test "WebDAV close reuse fences active filesystem and response owners until their completion" {
    var queue = try q.Queue.init(a, .{ .http = .{ .body_bytes = 32 } });
    defer queue.deinit();
    _ = try queue.submit(1, get ++ put);
    const old = queue.takeFilesystem().?;
    const old_generation = old.generation;
    queue.close(1);
    try t.expectEqual(1, queue.diagnostics().pending_jobs);
    try t.expect(queue.diagnostics().retained() > 0);
    _ = try queue.submit(1, get);
    try t.expectEqual(null, queue.takeFilesystem());
    try empty(&queue, old);
    try t.expectEqual(null, queue.takeResponse());
    try t.expectEqual(1, queue.diagnostics().discarded);
    const fresh = queue.takeFilesystem().?;
    try t.expect(fresh.generation > old_generation);
    try empty(&queue, fresh);
    const sending = queue.takeResponse().?;
    queue.close(1);
    _ = try queue.submit(1, put);
    try t.expectEqual(null, queue.takeFilesystem());
    queue.responseDone(sending, false); // Must not terminate the newer generation.
    const latest = queue.takeFilesystem().?;
    try empty(&queue, latest);
    queue.responseDone(queue.takeResponse().?, true);
    try t.expectEqual(0, queue.diagnostics().retained());
}
test "WebDAV failed delivery cancels queued mutations and shutdown drains retained owners" {
    var queue = try q.Queue.init(a, .{ .http = .{ .body_bytes = 32 } });
    defer queue.deinit();
    _ = try queue.submit(1, get ++ put);
    const job = queue.takeFilesystem().?;
    try empty(&queue, job);
    queue.responseDone(queue.takeResponse().?, false);
    try t.expectEqual(null, queue.takeFilesystem());
    try t.expectEqual(2, queue.diagnostics().cancelled);
    _ = try queue.submit(2, get);
    const active = queue.takeFilesystem().?;
    queue.stop();
    try t.expectError(error.Closed, queue.submit(1, get));
    try t.expect(queue.diagnostics().retained() > 0);
    queue.filesystemDone(active, .{ .failure = error.FileReadFailed });
    try t.expectEqual(0, queue.diagnostics().retained());
}
test "WebDAV response reservations cover slow sends and enforce generated response ceiling" {
    var queue = try q.Queue.init(a, .{ .clients = 1, .retained_bytes = 5000, .http = .{ .body_bytes = 0 } });
    defer queue.deinit();
    _ = try queue.submit(1, get);
    try t.expectError(error.TooManyClients, queue.submit(2, get));
    const job = queue.takeFilesystem().?;
    try t.expectError(error.RetainedBytesExceeded, queue.submit(1, get));
    queue.filesystemDone(job, .{ .bytes = try a.alloc(u8, 4097) });
    const sending = queue.takeResponse().?;
    try t.expectEqual(error.BodyTooLarge, sending.outcome.?.failure);
    try t.expect(queue.diagnostics().reserved_bytes == 4096);
    queue.responseDone(sending, true);
    try t.expectEqual(0, queue.diagnostics().retained());
}

test "WebDAV compatibility state shares budgets and excludes native same-ID owners" {
    var queue = try s.webdav_queue.Queue.init(a, .{ .clients = 2, .http = .{ .body_bytes = 0 } });
    defer queue.deinit();
    try queue.beginLegacy(1, "GET / HTTP/1.1\r\n");
    try t.expect(try queue.nextLegacy(1) == null);
    queue.endLegacy(1);
    try t.expectError(error.InvalidRequest, queue.submit(1, "\r\n"));
    _ = try queue.submit(2, "GET /2 HTTP/1.1\r\n\r\n");
    try t.expectError(error.TooManyClients, queue.beginLegacy(3, "GET /"));
    try t.expectError(error.InvalidRequest, queue.beginLegacy(2, "GET /"));
    try queue.beginLegacy(1, "\r\n");
    const request = (try queue.nextLegacy(1)).?;
    defer request.deinit();
    try t.expectEqualStrings("/", request.target);
    queue.closeAll();
    // A close can remove buffers, but an already borrowed compatibility
    // filesystem operation still prevents this ID entering the native queue.
    try t.expectError(error.InvalidRequest, queue.submit(1, "GET / HTTP/1.1\r\n\r\n"));
    queue.endLegacy(1);
    _ = try queue.submit(1, "GET / HTTP/1.1\r\n\r\n");
    const job = queue.takeFilesystem().?;
    queue.closeAll();
    try t.expectError(error.InvalidRequest, queue.beginLegacy(1, "GET /"));
    queue.filesystemDone(job, .{ .failure = error.Cancelled });
    try queue.beginLegacy(1, "GET /");
    queue.endLegacy(1);
}

test "WebDAV compatibility consumed prefixes and memory limit are preserved" {
    var queue = try s.webdav_queue.Queue.init(a, .{ .jobs = 1, .retained_bytes = 128, .http = .{ .body_bytes = 0 } });
    defer queue.deinit();
    try queue.beginLegacy(1, "GET /1 HTTP/1.1\r\n\r\nGET /2 HTTP/1.1\r\n\r\ninvalid\r\n\r\n");
    for (0..2) |_| {
        const request = (try queue.nextLegacy(1)).?;
        request.deinit();
    }
    try t.expectError(error.InvalidRequest, queue.nextLegacy(1));
    queue.endLegacy(1);
    try t.expectEqual("invalid\r\n\r\n".len, queue.diagnostics().buffered_bytes);
    try t.expectError(error.BodyTooLarge, queue.beginLegacy(2, &(@as([128]u8, @splat('x')))));
    queue.closeAll();
    try t.expectEqual(0, queue.diagnostics().retained());
}
