import CSpiceZig

// A lease owns its native runner and retains Runtime through detach and join.
// Native operations synchronize internally. The route only borrows the runner;
// it cannot retain this lease or form an ownership cycle back to Runtime.
final class ZigAudioLease: @unchecked Sendable {
    let runtime: ZigRuntime
    let raw: OpaquePointer
    let recording: UInt8

    init(runtime: ZigRuntime, recording: Bool, maximum: UInt32, interval: UInt32) throws {
        self.runtime = runtime
        self.recording = recording ? 1 : 0
        var options = SpiceZigAudioOptions()
        spice_zig_audio_options(&options)
        options.playback = recording ? 0 : 1
        options.capture = recording ? 1 : 0
        options.maximum_queued_ms = maximum
        options.delay_interval_ms = interval
        var runner: OpaquePointer?
        let created = spice_zig_audio_create(runtime.raw, &options, &runner)
        guard created == 0, let runner else { throw zigError(created) }
        let attached = spice_zig_audio_route_attach(runtime.audioRoute, self.recording, runner)
        guard attached == 0 else {
            spice_zig_audio_destroy(runner)
            throw zigError(attached)
        }
        raw = runner
    }

    func join() {
        spice_zig_audio_route_detach(runtime.audioRoute, recording, raw)
        spice_zig_audio_join(raw)
    }

    deinit {
        spice_zig_audio_route_detach(runtime.audioRoute, recording, raw)
        spice_zig_audio_destroy(raw)
    }
}
