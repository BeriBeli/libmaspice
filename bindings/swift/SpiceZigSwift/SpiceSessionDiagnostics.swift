import Foundation
import CSpiceZig

/// Best-effort, aggregate-only evidence about the display pipeline.
///
/// Counters accumulate from the most recent `SpiceSession.connect` attempt and
/// include active and retired display channels. Channel-state samples combine
/// current values from active channels with the last values observed when
/// retired channels closed. Depending on the field, those samples are summed,
/// ORed, or retained as a session maximum; they must not be interpreted as
/// strictly live gauges. The snapshot is assembled across actors and is not
/// atomic.
///
/// This type intentionally contains no per-frame log or timestamp, pixel data,
/// or native buffer handles. It does not measure server or transport latency
/// before `ChannelConnection.receive()` returns a complete framed message.
/// Bounded histograms summarize receive-to-surface-apply, publisher, and
/// GPU-presentation timing without retaining individual samples.
/// Presentation counters are populated when a desktop view subscribes to this
/// session's desktop source. Advanced-video counters cover H.264/H.265 decoding
/// and do not describe the MJPEG path. `advancedVideoPresentedFrames` is the
/// subset of Metal presentation events whose immutable canonical revision was
/// committed by native H.264/H.265 composition.
///
/// `totalIOSurfaceAllocatedBytes` is process-wide live state.
/// `surfaceAllocatedBytes` is live session-budget usage, and
/// `maximumSurfaceBytes` is its configured limit rather than a peak value.
public struct SpiceSessionDiagnostics: Sendable, Equatable {
    public internal(set) var displayChannelCount: Int = 0
    public internal(set) var damageOperations: UInt64 = 0
    public internal(set) var damageBytes: UInt64 = 0
    public internal(set) var snapshots: UInt64 = 0
    public internal(set) var fullFrameCopyBytes: UInt64 = 0
    public internal(set) var partialFrameCopyBytes: UInt64 = 0
    public internal(set) var directIOSurfaceWriteBytes: UInt64 = 0
    public internal(set) var cpuMaterializations: UInt64 = 0
    public internal(set) var cpuMaterializationBytes: UInt64 = 0
    public internal(set) var poolExhaustions: UInt64 = 0
    public internal(set) var inFlightLeases: Int = 0
    public internal(set) var revisionedBackingEnabled = false
    public internal(set) var revisionedAllocatedFrames: Int = 0
    public internal(set) var revisionedAllocatedBytes: Int = 0
    public internal(set) var totalIOSurfaceAllocatedBytes: Int = 0
    public internal(set) var gpuCopyBytes: UInt64 = 0
    public internal(set) var gpuErrors: UInt64 = 0
    public internal(set) var nativeVideoFrames: UInt64 = 0
    public internal(set) var nativeVideoFallbacks: UInt64 = 0
    public internal(set) var recommendedMaximumWorkingSetSize: UInt64 = 0
    public internal(set) var currentMetalAllocatedSize: UInt64 = 0
    public internal(set) var publisherSubmissions: UInt64 = 0
    public internal(set) var publisherSnapshotAttempts: UInt64 = 0
    public internal(set) var publisherEmittedFrames: UInt64 = 0
    public internal(set) var publisherEmittedIOSurfaceFrames: UInt64 = 0
    public internal(set) var publisherEmittedCPUOnlyFrames: UInt64 = 0
    public internal(set) var publisherStaleSnapshots: UInt64 = 0
    public internal(set) var publisherPendingEvictions: UInt64 = 0
    public internal(set) var publisherPendingSurfaces: Int = 0
    public internal(set) var publisherFlushes: UInt64 = 0
    public internal(set) var publisherFlushesWithoutEmission: UInt64 = 0
    public internal(set) var publisherDemandSuppressedSubmissions: UInt64 = 0
    public internal(set) var publisherPendingRevisionCoalesces: UInt64 = 0
    public internal(set) var publisherPreparedFrameCoalesces: UInt64 = 0
    public internal(set) var publisherDemandedSurfaces: Int = 0
    public internal(set) var publisherPreparedFrames: Int = 0
    public internal(set) var desktopDeliveredSnapshots: UInt64 = 0
    public internal(set) var desktopStreamCoalesces: UInt64 = 0
    public internal(set) var desktopHandlerDeliveries: UInt64 = 0
    public internal(set) var desktopSubscriptions: Int = 0
    public internal(set) var desktopVisibleSubscriptions: Int = 0
    public internal(set) var videoDecoderSessionCreations: UInt64 = 0
    public internal(set) var videoHardwareSessions: UInt64 = 0
    public internal(set) var videoSoftwareSessions: UInt64 = 0
    public internal(set) var videoHardwareQueryFailures: UInt64 = 0
    public internal(set) var videoDecodedFrames: UInt64 = 0
    public internal(set) var videoDroppedFrames: UInt64 = 0
    public internal(set) var videoCPUMaterializations: UInt64 = 0
    public internal(set) var mjpegDecoderHandleCreations: UInt64 = 0
    public internal(set) var mjpegDecodedFrames: UInt64 = 0
    public internal(set) var mjpegIOSurfaceFrames: UInt64 = 0
    public internal(set) var mjpegDataFallbacks: UInt64 = 0
    public internal(set) var mjpegIOSurfaceAllocations: UInt64 = 0
    public internal(set) var mjpegPeakBuffersInUse: Int = 0
    public internal(set) var mjpegPeakConcurrentDecodes: Int = 0
    public internal(set) var mjpegFramesSupersededBeforeDecode: UInt64 = 0
    public internal(set) var advancedCPUFallbackFrames: UInt64 = 0
    public internal(set) var metalGenerationDisableCount: UInt64 = 0
    public internal(set) var firstMetalGenerationDisableReason: String?
    public internal(set) var surfaceAllocatedBytes: Int = 0
    public internal(set) var maximumSurfaceBytes: Int = 0
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

    public static let empty = Self()

    public internal(set) var publisherBatchStartGap: SpiceTimingSummary = .empty

    /// Gap between the receive-completion timestamps of successive publisher
    /// batches. This begins after transport framing, not at the server.
    public internal(set) var publisherFramedReceiveBatchStartGap: SpiceTimingSummary = .empty

    /// Time from receiving a complete display message through image decode and
    /// applying its resulting pixels to the surface, before protocol ACK work.
    public internal(set) var publisherMessageReceiveToSurfaceReady: SpiceTimingSummary = .empty

    /// Actor handoff time from the completed surface apply to publisher entry.
    public internal(set) var publisherSurfaceReadyToSubmit: SpiceTimingSummary = .empty

    public internal(set) var publisherFlushStartGap: SpiceTimingSummary = .empty

    public internal(set) var publisherFlushSchedulingDelay: SpiceTimingSummary = .empty

    public internal(set) var publisherSnapshotDuration: SpiceTimingSummary = .empty

    public internal(set) var publisherEmitDuration: SpiceTimingSummary = .empty

    public internal(set) var viewUpdateToMetalCommit: SpiceTimingSummary = .empty

    /// Time from the ready timestamp of the latest accepted desktop revision
    /// that is actually selected until the AppKit presentation scheduler makes
    /// that selection. This is not the first update in its coalescing window;
    /// the property name remains source-compatible with SwiftSpice 0.2.5.
    public internal(set) var desktopReadyToDisplayLink: SpiceTimingSummary = .empty

    public internal(set) var metalCommitToCompletion: SpiceTimingSummary = .empty

    public internal(set) var metalRequestToPresented: SpiceTimingSummary = .empty

}

extension ZigRuntime {
    func diagnosticsSnapshot() -> SpiceSessionDiagnostics {
        var p = SpiceZigPipelineMetrics()
        var sourceMetrics = SpiceZigSourceMetrics()
        precondition(spice_zig_desktop_pipeline_metrics(raw, &p) == 0)
        precondition(spice_zig_source_metrics(source, &sourceMetrics) == 0)
        var result = SpiceSessionDiagnostics.empty
        result.displayChannelCount = Int(clamping: p.display_channels)
        result.damageOperations = p.damage_operations
        result.damageBytes = p.damage_bytes
        result.snapshots = p.snapshots
        result.fullFrameCopyBytes = p.full_copy_bytes
        result.partialFrameCopyBytes = p.partial_copy_bytes
        result.directIOSurfaceWriteBytes = p.direct_native_write_bytes
        result.cpuMaterializations = p.cpu_materializations
        result.cpuMaterializationBytes = p.cpu_materialization_bytes
        result.poolExhaustions = p.pool_exhaustions
        result.inFlightLeases = Int(clamping: p.in_flight_publications)
        result.revisionedAllocatedFrames = Int(clamping: p.allocated_frames)
        result.revisionedAllocatedBytes = Int(clamping: p.allocated_bytes)
        result.totalIOSurfaceAllocatedBytes = Int(clamping: p.process_native_allocated_bytes)
        result.gpuCopyBytes = p.gpu_copy_bytes
        result.gpuErrors = p.gpu_errors
        result.nativeVideoFrames = p.native_video_frames
        result.nativeVideoFallbacks = p.native_fallbacks
        result.recommendedMaximumWorkingSetSize = p.recommended_working_set
        result.currentMetalAllocatedSize = p.metal_allocated_bytes
        result.surfaceAllocatedBytes = Int(clamping: p.surface_bytes)
        result.maximumSurfaceBytes = Int(clamping: p.maximum_surface_bytes)
        result.publisherSubmissions = p.publisher_submissions
        result.publisherSnapshotAttempts = p.publisher_snapshots
        result.publisherEmittedFrames = p.publisher_emitted
        result.publisherEmittedIOSurfaceFrames = p.publisher_emitted_native
        result.publisherEmittedCPUOnlyFrames = p.publisher_emitted_cpu
        result.publisherStaleSnapshots = p.publisher_stale
        result.publisherPendingEvictions = p.publisher_evictions
        result.publisherPendingSurfaces = Int(clamping: p.publisher_pending)
        result.publisherFlushes = p.publisher_flushes
        result.publisherFlushesWithoutEmission = p.publisher_empty_flushes
        result.publisherDemandSuppressedSubmissions = p.publisher_suppressed
        result.publisherPendingRevisionCoalesces = p.publisher_coalesced
        result.publisherPreparedFrameCoalesces = p.publisher_prepared_coalesces
        result.publisherDemandedSurfaces = Int(clamping: p.publisher_demanded)
        result.publisherPreparedFrames = Int(clamping: p.publisher_prepared)
        result.videoDecoderSessionCreations = p.video_sessions
        result.videoHardwareSessions = p.video_hardware
        result.videoSoftwareSessions = p.video_software
        result.videoHardwareQueryFailures = p.video_query_failures
        result.videoDecodedFrames = p.video_decoded
        result.videoDroppedFrames = p.video_dropped
        result.videoCPUMaterializations = p.video_materializations
        result.mjpegDecoderHandleCreations = p.mjpeg_handles
        result.mjpegDecodedFrames = p.mjpeg_decoded
        result.mjpegIOSurfaceFrames = p.mjpeg_native
        result.mjpegDataFallbacks = p.mjpeg_data_fallbacks
        result.mjpegIOSurfaceAllocations = p.mjpeg_allocations
        result.mjpegPeakBuffersInUse = Int(clamping: p.mjpeg_peak_buffers)
        result.mjpegPeakConcurrentDecodes = Int(clamping: p.mjpeg_peak_decodes)
        result.mjpegFramesSupersededBeforeDecode = p.mjpeg_superseded
        result.advancedCPUFallbackFrames = p.advanced_cpu_fallbacks
        result.metalGenerationDisableCount = p.native_disables
        result.revisionedBackingEnabled = p.native_enabled != 0
        result.firstMetalGenerationDisableReason = p.first_disable_reason == 0 ? (initializationFallback ? "MetalUnavailable" : nil)
            : p.first_disable_reason == 1 ? "MetalUnavailable" : "GPUFailed"
        result.publisherBatchStartGap = SpiceTimingSummary(p.batch_start_gap)
        result.publisherFramedReceiveBatchStartGap = SpiceTimingSummary(p.framed_receive_batch_start_gap)
        result.publisherMessageReceiveToSurfaceReady = SpiceTimingSummary(p.receive_to_ready)
        result.publisherSurfaceReadyToSubmit = SpiceTimingSummary(p.ready_to_submit)
        result.publisherFlushStartGap = SpiceTimingSummary(p.flush_start_gap)
        result.publisherFlushSchedulingDelay = SpiceTimingSummary(p.flush_scheduling_delay)
        result.publisherSnapshotDuration = SpiceTimingSummary(p.snapshot_duration)
        result.publisherEmitDuration = SpiceTimingSummary(p.emit_duration)
        result.desktopDeliveredSnapshots = sourceMetrics.delivered
        result.desktopStreamCoalesces = sourceMetrics.coalesced
        result.desktopHandlerDeliveries = sourceMetrics.handler_deliveries
        result.desktopSubscriptions = Int(clamping: sourceMetrics.subscriptions)
        result.desktopVisibleSubscriptions = Int(clamping: sourceMetrics.visible)
        let presentation = SpicePresentationDiagnostics(owner: diagnostics).snapshot()
        result.metalPresentedFrames = presentation.metalPresentedFrames
        result.advancedVideoPresentedFrames = presentation.advancedVideoPresentedFrames
        result.metalPresentationErrors = presentation.metalPresentationErrors
        result.cpuFallbackFrames = presentation.cpuFallbackFrames
        result.metalUnavailableFallbackFrames = presentation.metalUnavailableFallbackFrames
        result.missingIOSurfaceFallbackFrames = presentation.missingIOSurfaceFallbackFrames
        result.ioSurfaceDimensionMismatchFallbackFrames = presentation.ioSurfaceDimensionMismatchFallbackFrames
        result.pixelFormatMismatchFallbackFrames = presentation.pixelFormatMismatchFallbackFrames
        result.textureCreationFailedFallbackFrames = presentation.textureCreationFailedFallbackFrames
        result.metalCommandFailureFallbackFrames = presentation.metalCommandFailureFallbackFrames
        result.lastCPUFallbackReason = presentation.lastCPUFallbackReason
        result.metalFramesSupersededBeforeDraw = presentation.metalFramesSupersededBeforeDraw
        result.metalDrawableMisses = presentation.metalDrawableMisses
        result.metalCommandCreationFailures = presentation.metalCommandCreationFailures
        result.metalCommandBuffersCommitted = presentation.metalCommandBuffersCommitted
        result.metalTextureCacheHits = presentation.metalTextureCacheHits
        result.metalTextureCacheMisses = presentation.metalTextureCacheMisses
        result.metalTextureCacheEvictions = presentation.metalTextureCacheEvictions
        result.metalGPUBusySkips = presentation.metalGPUBusySkips
        result.desktopDisplayLinkWakeups = presentation.desktopDisplayLinkWakeups
        result.desktopDisplayLinkTicks = presentation.desktopDisplayLinkTicks
        result.desktopDisplayLinkIdlePauses = presentation.desktopDisplayLinkIdlePauses
        result.desktopImmediateSelections = presentation.desktopImmediateSelections
        result.viewUpdateToMetalCommit = presentation.viewUpdateToMetalCommit
        result.desktopReadyToDisplayLink = presentation.desktopReadyToDisplayLink
        result.metalCommitToCompletion = presentation.metalCommitToCompletion
        result.metalRequestToPresented = presentation.metalRequestToPresented
        return result
    }
}
