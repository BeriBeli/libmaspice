const s = @import("spice");
export fn video_failure_classify(codec: u8, stage: u8, status: i32, output: *[3]i32) void {
    const failure: anyerror = switch (stage) {
        0 => error.UnsupportedVideoFormat,
        1 => error.VideoSessionFailed,
        2 => error.VideoConfigurationFailed,
        3 => error.VideoHardwareQueryFailed,
        4 => error.VideoHardwareUnavailable,
        5 => error.VideoDecodeFailed,
        else => error.DimensionMismatch,
    };
    const value = s.video_failure.classify(if (codec == 0) .h264 else .h265, failure, status);
    output.* = if (value) |v| .{ if (v.reason == .hardware_unavailable) 1 else 2, @intFromBool(v.status != null), v.status orelse 0 } else .{ 0, 0, 0 };
}
