//! Schema-2 interaction evidence. Strings are borrowed by Record; decoded
//! records own all strings through Parsed. Encoding never trusts supplied valid.
const std = @import("std");
pub const Action = enum { click, key, motion };
pub const maximum_record_bytes = 64 * 1024;
// Declaration order is canonical JSON lexicographic key order (Swift .sortedKeys).
pub const Record = struct {
    action_class: Action,
    delivery_sequence: ?u64 = null,
    desktop_generation: ?u64 = null,
    display_channel_id: ?u8 = null,
    display_receive_ns: ?u64 = null,
    frame_revision: ?u64 = null,
    guest_marker_drawn_ns: ?u64 = null,
    guest_received_ns: ?u64 = null,
    host_input_ns: ?u64 = null,
    invalid_reason: ?[]const u8 = null,
    marker_checksum: ?[]const u8 = null,
    marker_revision: ?u64 = null,
    metal_commit_ns: ?u64 = null,
    motion_ack_ns: ?u64 = null,
    order: u64,
    pair_id: []const u8,
    presented_ns: ?u64 = null,
    run_id: []const u8,
    scheduled_ns: ?u64 = null,
    schema_version: u64 = 2,
    selected_revision_ready_ns: ?u64 = null,
    selection_ns: ?u64 = null,
    send_completed_ns: ?u64 = null,
    send_started_ns: ?u64 = null,
    surface_generation: ?u64 = null,
    surface_id: ?u32 = null,
    surface_ready_ns: ?u64 = null,
    token: []const u8,
    valid: bool = false,
    version: []const u8,
    pub fn failure(self: Record, external: ?[]const u8) ?[]const u8 {
        if (external) |reason| return if (reason.len == 0) "invalid_reason_empty" else reason;
        if (self.pair_id.len == 0) return "invalid_pair_id";
        if (self.version.len == 0) return "invalid_version";
        if (self.run_id.len == 0) return "invalid_run_id";
        if (!lowerHex(self.token, 16)) return "invalid_token";
        const scheduled = self.scheduled_ns orelse return "missing_scheduled";
        const input = self.host_input_ns orelse return "missing_host_input";
        const started = self.send_started_ns orelse return "missing_send_started";
        const completed = self.send_completed_ns orelse return "missing_send_completed";
        const guest_received = self.guest_received_ns orelse return "missing_guest_received";
        const guest_drawn = self.guest_marker_drawn_ns orelse return "missing_guest_marker_drawn";
        if (self.marker_revision == null) return "missing_marker_revision";
        const checksum = self.marker_checksum orelse return "missing_marker_checksum";
        if (!lowerHex(checksum, 8)) return "invalid_marker_checksum";
        const received = self.display_receive_ns orelse return "missing_display_receive";
        const ready = self.surface_ready_ns orelse return "missing_surface_ready";
        const selected_ready = self.selected_revision_ready_ns orelse return "missing_selected_revision_ready";
        const selected = self.selection_ns orelse return "missing_selection";
        const committed = self.metal_commit_ns orelse return "missing_metal_commit";
        const presented = self.presented_ns orelse return "missing_presented";
        if (self.display_channel_id == null) return "missing_display_channel_id";
        if (self.surface_id == null) return "missing_surface_id";
        if (self.frame_revision == null) return "missing_frame_revision";
        if (self.surface_generation == null) return "missing_surface_generation";
        if (self.desktop_generation == null) return "missing_desktop_generation";
        if (self.delivery_sequence == null) return "missing_delivery_sequence";
        if (!(scheduled <= input and input <= started and started <= completed and started <= received and received <= ready and ready <= selected_ready and selected_ready <= selected and selected <= committed and committed <= presented and guest_received <= guest_drawn)) return "non_monotonic_timestamps";
        if (self.motion_ack_ns) |ack| if (!(started <= ack and ack <= presented)) return "non_monotonic_timestamps";
        return null;
    }
    pub fn derived(self: Record) Record {
        var result = self;
        result.schema_version = 2;
        result.invalid_reason = self.failure(self.invalid_reason);
        result.valid = result.invalid_reason == null;
        return result;
    }
    pub fn sendToDisplay(self: Record) ?u64 {
        return (self.display_receive_ns orelse return null) -| (self.send_completed_ns orelse return null);
    }
    pub fn encode(self: Record, allocator: std.mem.Allocator) ![]u8 {
        // Limit prior to allocation; JSON escaping can expand strings at most 6x.
        // The exact encoded length is checked after writing into a fixed bound.
        inline for (.{ "pair_id", "version", "run_id", "token" }) |name| {
            const value = @field(self, name);
            if (value.len > maximum_record_bytes) return error.RecordTooLarge;
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUTF8;
        }
        inline for (.{ "invalid_reason", "marker_checksum" }) |name| if (@field(self, name)) |value| {
            if (value.len > maximum_record_bytes) return error.RecordTooLarge;
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUTF8;
        };
        var buffer: [maximum_record_bytes - 1]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        std.json.Stringify.value(self.derived(), .{ .emit_null_optional_fields = false }, &writer) catch return error.RecordTooLarge;
        return allocator.dupe(u8, writer.buffered());
    }
};
pub fn lowerHex(value: []const u8, length: usize) bool {
    if (value.len != length) return false;
    for (value) |c| if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return false;
    return true;
}
fn equalOptional(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |value| return if (b) |other| std.mem.eql(u8, value, other) else false;
    return b == null;
}
fn evidenceFailure(reason: []const u8) bool {
    const names = [_][]const u8{ "invalid_pair_id", "invalid_version", "invalid_run_id", "invalid_token", "missing_scheduled", "missing_host_input", "missing_send_started", "missing_send_completed", "missing_guest_received", "missing_guest_marker_drawn", "missing_marker_revision", "missing_marker_checksum", "invalid_marker_checksum", "missing_display_receive", "missing_surface_ready", "missing_selected_revision_ready", "missing_selection", "missing_metal_commit", "missing_presented", "missing_frame_revision", "missing_display_channel_id", "missing_surface_id", "missing_surface_generation", "missing_desktop_generation", "missing_delivery_sequence", "non_monotonic_timestamps" };
    for (names) |name| if (std.mem.eql(u8, reason, name)) return true;
    return false;
}
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Record) {
    if (bytes.len >= maximum_record_bytes) return error.RecordTooLarge;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value != .object or !parsed.value.object.contains("schema_version") or !parsed.value.object.contains("valid")) return error.MissingField;
    const wire = try std.json.parseFromValueLeaky(Record, parsed.arena.allocator(), parsed.value, .{ .ignore_unknown_fields = true });
    if (wire.schema_version != 2) return error.UnsupportedSchema;
    const derived = wire.derived();
    if (wire.valid != derived.valid or !equalOptional(wire.invalid_reason, derived.invalid_reason)) return error.InconsistentValidation;
    if (wire.failure(null) == null) if (wire.invalid_reason) |reason| if (evidenceFailure(reason)) return error.InconsistentValidation;
    return .{ .arena = parsed.arena, .value = wire };
}
