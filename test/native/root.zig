const spice = @import("spice");
test {
    _ = spice.protocol;
    _ = spice.ticket;
    _ = spice.lz;
    _ = @import("wire_tests.zig");
    _ = @import("core_tests.zig");
    _ = @import("channel_tests.zig");
    _ = @import("main_tests.zig");
    _ = @import("session_tests.zig");
    _ = @import("glz_tests.zig");
    _ = @import("image_cache_tests.zig");
    _ = @import("image_wait_tests.zig");
    _ = @import("stream_tests.zig");
    _ = @import("video_failure_tests.zig");
    _ = @import("desktop_tests.zig");
    _ = @import("audio_tests.zig");
    _ = @import("audio_ring_tests.zig");
    _ = @import("audio_runner_tests.zig");
    _ = @import("peripheral_tests.zig");
    _ = @import("agent_services_tests.zig");
    _ = @import("agent_runner_tests.zig");
}
