//! Content-free lifetime observations of the Agent wire/clipboard path.
const protocol = @import("agent_services_wire.zig");
pub const Metrics = extern struct {
    capability_attempts: u64 = 0,
    capability_sent: u64 = 0,
    capability_failures: u64 = 0,
    inbound: u64 = 0,
    current_protocol: u64 = 0,
    unexpected_protocol: u64 = 0,
    capabilities: u64 = 0,
    clipboard: u64 = 0,
    data: u64 = 0,
    grab: u64 = 0,
    request: u64 = 0,
    release: u64 = 0,
    monitor_replies: u64 = 0,
    files: u64 = 0,
    other: u64 = 0,
    decode_failures: u64 = 0,
    clipboard_failures: u64 = 0,
    has_peer: u32 = 0,
    peer_legacy: u32 = 0,
    peer_demand: u32 = 0,
    last_failure: u32 = 0,
    has_inbound: u32 = 0,
    last_protocol: u32 = 0,
    last_kind: u32 = 0,
    reserved: u32 = 0,
    pub fn received(self: *Metrics, version: u32, kind: u32) void {
        self.inbound +%= 1;
        self.has_inbound = 1;
        self.last_protocol = version;
        self.last_kind = kind;
        if (version == 1) self.current_protocol +%= 1 else self.unexpected_protocol +%= 1;
        switch (kind) {
            6 => self.capabilities +%= 1,
            4 => {
                self.clipboard +%= 1;
                self.data +%= 1;
            },
            7 => {
                self.clipboard +%= 1;
                self.grab +%= 1;
            },
            8 => {
                self.clipboard +%= 1;
                self.request +%= 1;
            },
            9 => {
                self.clipboard +%= 1;
                self.release +%= 1;
            },
            3 => self.monitor_replies +%= 1,
            10, 11, 12 => self.files +%= 1,
            else => self.other +%= 1,
        }
    }
    pub fn peer(self: *Metrics, caps: protocol.Capabilities) void {
        self.has_peer = 1;
        self.peer_legacy = @intFromBool(caps.contains(3));
        self.peer_demand = @intFromBool(caps.contains(5));
    }
    // Codes mirror the fixed public category order, not an underlying error id.
    pub fn failure(self: *Metrics, reason: anyerror) void {
        self.clipboard_failures +%= 1;
        self.last_failure = switch (reason) {
            error.AgentUnavailable, error.AgentDisconnected => 1,
            error.ClipboardNotReady => 2,
            error.UnsolicitedClipboardData => 3,
            error.UnexpectedClipboardType => 4,
            error.OversizedGuestText => 5,
            error.InvalidUTF8 => 6,
            error.InvalidSize, error.Truncated, error.InvalidEnum => 7,
            error.PasteboardWriteFailed, error.PasteboardUnavailable => 9,
            error.ConnectionClosed, error.ConnectionFailed, error.TLSFailure, error.Timeout => 10,
            else => 11,
        };
    }
};
