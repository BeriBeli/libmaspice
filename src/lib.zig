//! One compilation unit for the complete C ABI. Shared modules (notably the
//! ticket export) must be instantiated once when foundational and desktop APIs
//! are linked into the same executable.
pub const std_options = @import("desktop_abi.zig").std_options;
comptime {
    _ = @import("abi.zig");
    _ = @import("desktop_abi.zig");
    _ = @import("host_view_native.zig");
}
