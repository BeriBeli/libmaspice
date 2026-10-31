const p = @import("generated.zig");

/// Called once per completed physical batch, including an empty LIST. Never
/// increment for every logical submessage; generation changes reset the window.
pub const Ack = struct {
    generation: ?u32 = null,
    window: u32 = 0,
    processed: u32 = 0,
    pub fn configure(self: *Ack, generation: u32, window: u32) void {
        self.* = .{ .generation = generation, .window = window };
    }
    pub fn didProcessBatch(self: *Ack) bool {
        if (self.generation == null or self.window == 0) return false;
        self.processed +|= 1;
        if (self.processed < self.window) return false;
        self.processed = 0;
        return true;
    }
};

/// Arrival margins, never decoder/presenter counts. Clock input is local
/// monotonic milliseconds; no idle timer emits an empty report.
pub const StreamReportWindow = struct {
    activation: p.SpiceMsgDisplayStreamActivateReport,
    started_ms: ?u64 = null,
    start_frame: u32 = 0,
    frames: u32 = 0,
    drops: u32 = 0,
    consecutive_drops: u32 = 0,
    pub fn record(self: *StreamReportWindow, time: u32, margin: i32, audio_delay: u32, now_ms: u64) ?p.SpiceMsgcDisplayStreamReport {
        if (self.frames == 0) {
            self.started_ms = now_ms;
            self.start_frame = time;
        }
        self.frames += 1;
        if (margin < 0) {
            self.drops += 1;
            self.consecutive_drops += 1;
        } else {
            self.consecutive_drops = 0;
        }
        const elapsed = now_ms -| self.started_ms.?;
        if (self.frames < self.activation.maximumWindowSize and elapsed < self.activation.timeoutMilliseconds and self.consecutive_drops < 3) return null;
        const report: p.SpiceMsgcDisplayStreamReport = .{
            .streamID = self.activation.streamID,
            .uniqueID = self.activation.uniqueID,
            .startFrameMultimediaTime = self.start_frame,
            .endFrameMultimediaTime = time,
            .frameCount = self.frames,
            .dropCount = self.drops,
            .lastFrameDelay = margin,
            .audioDelay = audio_delay,
        };
        self.started_ms = null;
        self.frames = 0;
        self.drops = 0;
        self.consecutive_drops = 0;
        return report;
    }
};
