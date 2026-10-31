//! Joined WebDAV executor. Feed ordered desktop observations before releasing
//! them. Runtime and filesystem are borrowed until destroy. The filesystem
//! allocator must match the runner allocator; returned response bytes transfer
//! to the admission queue. Runtime sends must honor the supplied cancellation.
//!
//! One bounded worker per admitted-job slot lets every runnable client progress
//! even while other clients await transport writes. Only filesystem_parallelism
//! workers enter filesystem operations at once; send waits hold no such permit.
//! Blocking regular-file syscalls cannot be forcibly cancelled: destroy joins
//! them, and close discards their results without retrying uncertain mutations.
const std = @import("std");
const sync = @import("sync.zig");
const cancel = @import("cancel.zig");
const queue = @import("webdav_queue.zig");
pub const Options = struct { channel_id: u8 = 0, filesystem_parallelism: usize = 2, limits: queue.Limits = .{} };
/// Shared by every attachment of one server. Lock order: gate, then Queue.
/// The gate is never held across filesystem or transport operations.
pub const Shared = struct {
    queue: queue.Queue,
    mutex: sync.Mutex = .{},
    changed: sync.Condition = .{},
    active_filesystems: usize = 0,
    filesystem_parallelism: usize,
    next_owner: u64 = 0,
    pub fn init(a: std.mem.Allocator, options: Options) !Shared {
        if (options.limits.jobs == 0 or options.limits.jobs > 64 or options.filesystem_parallelism == 0 or options.filesystem_parallelism > options.limits.jobs) return error.InvalidLimits;
        return .{ .queue = try queue.Queue.init(a, options.limits), .filesystem_parallelism = options.filesystem_parallelism };
    }
    pub fn deinit(self: *Shared) void {
        self.queue.deinit();
        self.changed.deinit();
        self.mutex.deinit();
    }
    pub fn close(self: *Shared, id: ?i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (id) |client| self.queue.close(client) else self.queue.closeAll();
        self.changed.broadcast();
    }
};
pub fn Runner(comptime Runtime: type, comptime Filesystem: type) type {
    return struct {
        const Self = @This();
        const Worker = struct {
            owner: *Self,
            thread: ?std.Thread = null,
            token: cancel.Token = .{},
            client: ?i64 = null,
        };
        allocator: std.mem.Allocator,
        runtime: *Runtime,
        filesystem: *const Filesystem,
        options: Options,
        shared: *Shared,
        owns_shared: bool = false,
        identity: u64,
        workers: []Worker,
        generation: u64 = 0,
        lifecycle: u64 = 0,
        live_workers: usize = 0,
        stopping: bool = false,
        failure: ?anyerror = null,
        pub fn create(a: std.mem.Allocator, runtime: *Runtime, filesystem: *const Filesystem, options: Options) !*Self {
            const shared = try a.create(Shared);
            errdefer a.destroy(shared);
            shared.* = try Shared.init(a, options);
            errdefer shared.deinit();
            const self = try createShared(a, runtime, filesystem, options.channel_id, shared);
            self.owns_shared = true;
            return self;
        }
        /// Borrows shared state and filesystem until destroy joins every worker.
        pub fn createShared(a: std.mem.Allocator, runtime: *Runtime, filesystem: *const Filesystem, channel_id: u8, shared: *Shared) !*Self {
            const self = try a.create(Self);
            errdefer a.destroy(self);
            const workers = try a.alloc(Worker, shared.queue.limits.jobs);
            errdefer a.free(workers);
            shared.mutex.lock();
            const identity = std.math.add(u64, shared.next_owner, 1) catch {
                shared.mutex.unlock();
                return error.InvalidLimits;
            };
            shared.next_owner = identity;
            shared.mutex.unlock();
            self.* = .{ .allocator = a, .runtime = runtime, .filesystem = filesystem, .options = .{ .channel_id = channel_id, .filesystem_parallelism = shared.filesystem_parallelism, .limits = shared.queue.limits }, .workers = workers, .shared = shared, .identity = identity };
            for (workers) |*worker| worker.* = .{ .owner = self };
            errdefer {
                self.shared.mutex.lock();
                self.stopping = true;
                self.shared.changed.broadcast();
                self.shared.mutex.unlock();
                for (workers) |*worker| {
                    if (worker.thread) |thread| thread.join();
                    worker.token.deinit();
                }
            }
            // Hold the lifecycle lock until all workers exist. Rollback joins
            // every successfully created worker before destroying shared state.
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();
            for (workers) |*worker| {
                worker.thread = try std.Thread.spawn(.{}, run, .{worker});
                self.live_workers += 1;
            }
            return self;
        }
        fn closeLocked(self: *Self, client: ?i64) void {
            if (client) |id| self.shared.queue.close(id) else self.shared.queue.closeAll();
            for (self.workers) |*worker| if (worker.client) |id| {
                if (client == null or client.? == id) worker.token.cancel();
            };
            self.shared.changed.broadcast();
        }
        fn stopLocked(self: *Self, failure: ?anyerror) void {
            if (self.stopping) return;
            self.stopping = true;
            self.failure = failure;
            if (self.owns_shared) self.shared.queue.stop() else if (self.lifecycle != 0) self.shared.queue.closeAll();
            for (self.workers) |*worker| worker.token.cancel();
            self.shared.changed.broadcast();
        }
        pub fn stop(self: *Self) void {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();
            self.stopLocked(null);
        }
        /// Exclusive with destroy/other join callers. stop first to end service.
        pub fn join(self: *Self) void {
            for (self.workers) |*worker| {
                if (worker.thread) |thread| thread.join();
                worker.thread = null;
            }
        }
        pub fn destroy(self: *Self) void {
            self.stop();
            self.join();
            for (self.workers) |*worker| worker.token.deinit();
            if (self.owns_shared) {
                self.shared.deinit();
                self.allocator.destroy(self.shared);
            }
            self.allocator.free(self.workers);

            self.allocator.destroy(self);
        }
        pub fn status(self: *Self) struct { finished: bool, failure: ?anyerror } {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();
            return .{ .finished = self.live_workers == 0, .failure = self.failure };
        }
        pub fn diagnostics(self: *Self) queue.Diagnostics {
            return self.shared.queue.diagnostics();
        }
        /// Admission is synchronous and transactional. Parsing errors terminate
        /// this service, so callers cannot continue an ambiguous HTTP stream.
        pub fn observe(self: *Self, event: Runtime.Event) !void {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();
            if (self.stopping) return error.Closed;
            if (event.generation < self.generation) return;
            if (event.lifecycle < self.lifecycle) return;
            if (event.lifecycle != self.lifecycle) {
                if (self.lifecycle != 0) self.closeLocked(null);
                self.lifecycle = event.lifecycle;
            }
            // Same-guest handoff retains HTTP prefixes, just like the Swift
            // server actor. Already admitted jobs keep their original transport
            // generation; completing a prefix admits a new-generation job.
            self.generation = event.generation;
            switch (event.value) {
                .disconnected, .failed => self.closeLocked(null),
                .child => |child| switch (child) {
                    .webdav => |value| {
                        if (event.key.id != self.options.channel_id) return;
                        switch (value) {
                            .request => |request| {
                                _ = self.shared.queue.submitFor(request.client, request.data.bytes(), event.generation, self.identity) catch |err| {
                                    self.stopLocked(err);
                                    return err;
                                };
                                self.shared.changed.broadcast();
                            },
                            .closed => |id| self.closeLocked(id),
                            .port => |port| if (port == .closed) self.closeLocked(null),
                            .initialized => |init| if (!init.opened) self.closeLocked(null),
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }
        fn send(self: *Self, worker: *Worker, generation: u64, job: *queue.Job) !void {
            const bytes = switch (job.outcome.?) {
                .bytes => |bytes| bytes,
                .failure => |failure| return failure,
            };
            var offset: usize = 0;
            // An empty payload is the mux client-close frame.
            while (offset < bytes.len or offset == 0) {
                const end = offset + @min(bytes.len - offset, 65535);
                try self.runtime.sendWebDAVAt(self.options.channel_id, generation, job.client, bytes[offset..end], &worker.token);
                offset = end;
                if (offset == bytes.len) break;
            }
        }
        fn run(worker: *Worker) void {
            const self = worker.owner;
            self.shared.mutex.lock();
            defer {
                self.live_workers -= 1;
                self.shared.changed.broadcast();
                self.shared.mutex.unlock();
            }
            while (!self.stopping) {
                const selected = if (self.shared.active_filesystems < self.options.filesystem_parallelism) self.shared.queue.takeFilesystemFor(self.identity, &worker.token) else null;
                const job = selected orelse {
                    self.shared.changed.wait(&self.shared.mutex);
                    continue;
                };
                const id = job.id;
                const generation = job.origin;
                worker.client = job.client;
                self.shared.active_filesystems += 1;
                self.shared.mutex.unlock();
                const outcome: queue.Outcome = if (self.filesystem.execute(job.request)) |bytes| .{ .bytes = bytes } else |err| .{ .failure = err };
                self.shared.mutex.lock();
                self.shared.active_filesystems -= 1;
                self.shared.queue.filesystemDone(job, outcome);
                self.shared.changed.broadcast();
                if (self.shared.queue.takeResponseID(id)) |response| {
                    self.shared.mutex.unlock();
                    const failure: ?anyerror = if (self.send(worker, generation, response)) |_| null else |err| err;
                    self.shared.mutex.lock();
                    const cancelled = worker.token.cancelled.load(.acquire);
                    self.shared.queue.responseDone(response, failure == null and !cancelled);
                    if (!cancelled) if (failure) |err| {
                        // A supervisor handoff may precede delivery of its
                        // observation. Old responses are discarded harmlessly.
                        if (err != error.StaleWebDAVGeneration) self.stopLocked(err);
                    };
                }
                worker.client = null;
                worker.token.deinit();
                worker.token = .{};
                self.shared.changed.broadcast();
            }
        }
    };
}
