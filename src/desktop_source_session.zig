//! Ordered desktop event adapter. A single event reader calls observe; Source
//! subscriptions may run concurrently. Runtime is borrowed until destroy. Hooks
//! pin its channel lease and logical guest epoch before enqueueing demand/ACK.
const std = @import("std");
const d = @import("desktop_snapshot.zig");
const source = @import("desktop_source.zig");
pub fn Session(comptime Runtime: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        runtime: *Runtime,
        source: *source.Source,
        generation: u64 = 0,
        lifecycle: u64 = 0,
        pointer: d.PointerMode = .absolute,
        connected: bool = false,
        pub fn create(a: std.mem.Allocator, runtime: *Runtime, options: source.Options) !*Self {
            const self = try a.create(Self);
            errdefer a.destroy(self);
            self.* = .{ .allocator = a, .runtime = runtime, .source = try source.Source.create(a, options) };
            return self;
        }
        /// Unbinding serializes with active Source hooks. Subscriptions and
        /// snapshots remain usable after this adapter and Runtime are destroyed.
        /// Join observe before destroy; handler callbacks must not destroy it.
        pub fn destroy(self: *Self) void {
            self.source.unbind();
            self.source.release();
            self.allocator.destroy(self);
        }
        fn deferred(err: anyerror) bool {
            return switch (err) {
                error.UnknownChannel, error.InvalidState, error.ConnectionClosed, error.StaleDesktopEpoch => true,
                else => false,
            };
        }
        fn demand(p: *anyopaque, lifecycle: u64, key: d.Key, visible: bool) !void {
            const runtime: *Runtime = @ptrCast(@alignCast(p));
            runtime.setFrameDemandAt(lifecycle, key.channel, key.surface, visible) catch |err| {
                if (!deferred(err)) return err;
            };
        }
        fn acknowledge(p: *anyopaque, lifecycle: u64, revision: d.Revision) !void {
            const runtime: *Runtime = @ptrCast(@alignCast(p));
            runtime.acknowledgeFrameAt(lifecycle, revision.channel, revision.surface) catch |err| {
                if (!deferred(err)) return err;
            };
        }
        pub fn observe(self: *Self, event: Runtime.Event) !void {
            if (event.generation < self.generation or event.lifecycle < self.lifecycle) return;
            const changed = event.generation != self.generation or event.lifecycle != self.lifecycle;
            const retaining = self.connected and event.lifecycle == self.lifecycle;
            if (!changed and !self.connected) return;
            if (event.mouse_mode) |mode| self.pointer = if (mode == 2) .absolute else .relative;
            // Supervisor emits completed before processing new-generation
            // receiver notices. The changed fallback also fences later attaches.
            if (changed and event.value != .disconnected and event.value != .failed) {
                self.source.unbind();
                try self.source.begin(self.pointer, retaining, false);
                self.generation = event.generation;
                self.lifecycle = event.lifecycle;
                self.connected = true;
                try self.source.bind(.{ .context = self.runtime, .lifecycle = self.lifecycle, .demand = demand, .acknowledge = acknowledge });
            }
            switch (event.value) {
                .disconnected, .failed => {
                    const was_connected = self.connected;
                    self.source.unbind();
                    self.connected = false;
                    self.generation = event.generation;
                    self.lifecycle = event.lifecycle;
                    if (was_connected) try self.source.begin(self.pointer, false, false);
                },
                .main => |main| switch (main) {
                    .mouse => |mouse| {
                        self.pointer = if (mouse.current == 2) .absolute else .relative;
                        try self.source.updatePointer(self.pointer);
                    },
                    else => {},
                },
                .child => |child| switch (child) {
                    .cursor => |cursor| if (cursor.kind != .cache_invalidated) try self.source.updateCursor(cursor.snapshot),
                    .display => |display| switch (display) {
                        .publication => |v| try self.source.receiveFrameTimed(event.key.id, v.frame, v.timing),
                        .drawing => |drawing| switch (drawing) {
                            .destroyed => |id| try self.source.surfaceDestroyed(.{ .channel = event.key.id, .surface = id }),
                            else => {},
                        },
                        else => {},
                    },
                    else => {},
                },
                else => {},
            }
        }
    };
}
