//! Public codec compatibility categories, preserving the existing Swift policy.
//! Constants are OSStatus ABI values from CoreMedia/VideoToolbox headers; the
//! native oracle validates them against the active SDK rather than guessing.
const Codec = @import("annexb.zig").Codec;
pub const Reason = enum { hardware_unavailable, unsupported_format };
pub const Failure = struct { codec: Codec, reason: Reason, status: ?i32 };
pub fn classify(codec: Codec, failure: anyerror, status: i32) ?Failure {
    switch (failure) {
        error.VideoHardwareUnavailable => return .{ .codec = codec, .reason = .hardware_unavailable, .status = null },
        error.VideoHardwareQueryFailed => return .{ .codec = codec, .reason = .hardware_unavailable, .status = status },
        error.UnsupportedVideoFormat => {
            // A missing native output with no error, or allocation failure, is
            // a backend failure rather than unsupported guest video.
            if (status == 0 or status == -12711) return null;
            return .{ .codec = codec, .reason = .unsupported_format, .status = status };
        },
        error.VideoSessionFailed, error.VideoDecodeFailed => {},
        else => return null,
    }
    const reason: Reason = switch (status) {
        -12910, -12916 => .unsupported_format,
        -12906, -12907, -12911, -12913, -12210, -17690, -17691, -17692 => .hardware_unavailable,
        else => return null,
    };
    return .{ .codec = codec, .reason = reason, .status = status };
}
