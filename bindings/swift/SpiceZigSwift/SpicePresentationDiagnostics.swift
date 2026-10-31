import CSpiceZig

/// A content-free reason why a desktop frame used AppKit CPU presentation.
public enum SpiceCPUPresentationFallbackReason: String, Sendable, Equatable {
    case metalUnavailable = "metal_unavailable"
    case missingIOSurface = "missing_iosurface"
    case ioSurfaceDimensionMismatch = "iosurface_dimension_mismatch"
    case pixelFormatMismatch = "pixel_format_mismatch"
    case textureCreationFailed = "texture_creation_failed"
    case metalCommandFailure = "metal_command_failure"
}

/// Best-effort aggregate evidence about desktop frame presentation.
public struct SpicePresentationMetrics: Sendable, Equatable {
    public internal(set) var metalPresentedFrames: UInt64 = 0
    public internal(set) var advancedVideoPresentedFrames: UInt64 = 0
    public internal(set) var metalPresentationErrors: UInt64 = 0
    public internal(set) var cpuFallbackFrames: UInt64 = 0
    public internal(set) var metalUnavailableFallbackFrames: UInt64 = 0
    public internal(set) var missingIOSurfaceFallbackFrames: UInt64 = 0
    public internal(set) var ioSurfaceDimensionMismatchFallbackFrames: UInt64 = 0
    public internal(set) var pixelFormatMismatchFallbackFrames: UInt64 = 0
    public internal(set) var textureCreationFailedFallbackFrames: UInt64 = 0
    public internal(set) var metalCommandFailureFallbackFrames: UInt64 = 0
    public internal(set) var lastCPUFallbackReason: SpiceCPUPresentationFallbackReason?
    public internal(set) var metalFramesSupersededBeforeDraw: UInt64 = 0
    public internal(set) var metalDrawableMisses: UInt64 = 0
    public internal(set) var metalCommandCreationFailures: UInt64 = 0
    public internal(set) var metalCommandBuffersCommitted: UInt64 = 0
    public internal(set) var metalTextureCacheHits: UInt64 = 0
    public internal(set) var metalTextureCacheMisses: UInt64 = 0
    public internal(set) var metalTextureCacheEvictions: UInt64 = 0
    public internal(set) var metalGPUBusySkips: UInt64 = 0
    public internal(set) var desktopDisplayLinkWakeups: UInt64 = 0
    public internal(set) var desktopDisplayLinkTicks: UInt64 = 0
    public internal(set) var desktopDisplayLinkIdlePauses: UInt64 = 0
    public internal(set) var desktopImmediateSelections: UInt64 = 0

    public internal(set) var viewUpdateToMetalCommit: SpiceTimingSummary = .empty

    /// Time from the selected latest desktop revision becoming ready until the
    /// AppKit presentation scheduler selects that revision. The property name
    /// remains source-compatible with SwiftSpice 0.2.5.
    public internal(set) var desktopReadyToDisplayLink: SpiceTimingSummary = .empty

    public internal(set) var metalCommitToCompletion: SpiceTimingSummary = .empty

    /// Time from selecting a desktop revision until CAMetalDrawable confirms
    /// that the drawable was actually presented by the display compositor.
    public internal(set) var metalRequestToPresented: SpiceTimingSummary = .empty

    public static let empty = Self()
}

// Native recorder retains Source independently and serializes all access.
final class ZigDiagnosticsOwner: @unchecked Sendable {
    let raw: OpaquePointer
    init(source: OpaquePointer) throws {
        var raw: OpaquePointer?
        let status = spice_zig_source_diagnostics(source, &raw)
        guard status == 0, let raw else { throw zigError(status) }
        self.raw = raw
    }
    deinit { spice_zig_diagnostics_destroy(raw) }
}

public final class SpicePresentationDiagnostics: Sendable {
    let owner: ZigDiagnosticsOwner?
    public init() { owner = nil }
    init(owner: ZigDiagnosticsOwner) { self.owner = owner }
    public func snapshot() -> SpicePresentationMetrics {
        guard let owner else { return .empty }
        var metrics = SpiceZigPresentationMetrics()
        precondition(spice_zig_diagnostics_metrics(owner.raw, &metrics) == 0)
        return SpicePresentationMetrics(native: metrics)
    }
}

extension SpiceTimingSummary {
    init(_ value: SpiceZigTimingSummary) {
        self.init(sampleCount: value.count,
                  p95Milliseconds: value.has_values == 0 ? nil : value.p95_ms,
                  maximumMilliseconds: value.has_values == 0 ? nil : value.maximum_ms)
    }
    init(_ value: SpiceZigPipelineTiming) {
        self.init(sampleCount: value.count,
                  p95Milliseconds: value.has_values == 0 ? nil : value.p95_ms,
                  maximumMilliseconds: value.has_values == 0 ? nil : value.maximum_ms)
    }
}

extension SpicePresentationMetrics {
    init(native: SpiceZigPresentationMetrics) {
        self.init()
        let c = withUnsafeBytes(of: native.counters) { Array($0.bindMemory(to: UInt64.self)) }
        let f = withUnsafeBytes(of: native.fallback_counts) { Array($0.bindMemory(to: UInt64.self)) }
        metalPresentedFrames = c[0]
        advancedVideoPresentedFrames = c[1]
        metalPresentationErrors = c[2]
        metalFramesSupersededBeforeDraw = c[3]
        metalDrawableMisses = c[4]
        metalCommandCreationFailures = c[5]
        metalCommandBuffersCommitted = c[6]
        metalTextureCacheHits = c[7]
        metalTextureCacheMisses = c[8]
        metalTextureCacheEvictions = c[9]
        metalGPUBusySkips = c[10]
        desktopDisplayLinkWakeups = c[11]
        desktopDisplayLinkTicks = c[12]
        desktopDisplayLinkIdlePauses = c[13]
        desktopImmediateSelections = c[14]
        cpuFallbackFrames = native.fallback_frames
        metalUnavailableFallbackFrames = f[0]
        missingIOSurfaceFallbackFrames = f[1]
        ioSurfaceDimensionMismatchFallbackFrames = f[2]
        pixelFormatMismatchFallbackFrames = f[3]
        textureCreationFailedFallbackFrames = f[4]
        metalCommandFailureFallbackFrames = f[5]
        let reasons: [SpiceCPUPresentationFallbackReason] = [.metalUnavailable, .missingIOSurface,
            .ioSurfaceDimensionMismatch, .pixelFormatMismatch, .textureCreationFailed, .metalCommandFailure]
        if native.has_fallback != 0 { lastCPUFallbackReason = reasons[Int(native.last_fallback)] }
        desktopReadyToDisplayLink = SpiceTimingSummary(native.latency.0)
        viewUpdateToMetalCommit = SpiceTimingSummary(native.latency.1)
        metalCommitToCompletion = SpiceTimingSummary(native.latency.2)
        metalRequestToPresented = SpiceTimingSummary(native.latency.3)
    }
}
