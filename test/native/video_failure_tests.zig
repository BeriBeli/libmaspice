const std = @import("std");
const s = @import("spice");
const t = std.testing;
test "video compatibility keeps native stage codec status and backend failures distinct" {
    for ([_]s.annexb.Codec{ .h264, .h265 }) |codec| {
        const software = s.video_failure.classify(codec, error.VideoHardwareUnavailable, 0).?;
        try t.expectEqual(codec, software.codec);
        try t.expectEqual(s.video_failure.Reason.hardware_unavailable, software.reason);
        try t.expect(software.status == null);
        const query = s.video_failure.classify(codec, error.VideoHardwareQueryFailed, -77).?;
        try t.expectEqual(@as(?i32, -77), query.status);
        try t.expect(s.video_failure.classify(codec, error.UnsupportedVideoFormat, 0) == null);
        try t.expect(s.video_failure.classify(codec, error.UnsupportedVideoFormat, -12711) == null);
        try t.expectEqual(s.video_failure.Reason.unsupported_format, s.video_failure.classify(codec, error.UnsupportedVideoFormat, -77).?.reason);
        try t.expect(s.video_failure.classify(codec, error.VideoConfigurationFailed, -12910) == null);
        try t.expect(s.video_failure.classify(codec, error.DimensionMismatch, -12910) == null);
        try t.expect(s.video_failure.classify(codec, error.VideoDecodeFailed, -77) == null);
    }
}
