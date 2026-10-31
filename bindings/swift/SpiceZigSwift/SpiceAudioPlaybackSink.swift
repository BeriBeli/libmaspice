import CSpiceZig
import Foundation

public enum SpiceAudioPlaybackSinkError: Error, Sendable, Equatable, CustomStringConvertible {
    case alreadyRunning
    case invalidConfiguration(String)
    case invalidPacket(String)
    case audioEngine(String)

    public var description: String {
        switch self {
        case .alreadyRunning:
            "audio playback sink is already running"
        case let .invalidConfiguration(reason):
            "invalid playback configuration: \(reason)"
        case let .invalidPacket(reason):
            "invalid playback packet: \(reason)"
        case let .audioEngine(reason):
            "audio engine failed: \(reason)"
        }
    }
}

public enum SpiceAudioPlaybackSinkEvent: Sendable, Equatable {
    case started(SpicePlaybackConfiguration)
    case stopped
    case muteChanged(Bool)
    case overflowResynchronized(droppedMilliseconds: UInt32)
    case oversizedPacketDropped(milliseconds: UInt32)
    case underrun
    case failed(SpiceAudioPlaybackSinkError)
}

public struct SpiceAudioPlaybackSinkStatistics: Sendable, Equatable {
    public let scheduledPackets: UInt64
    public let scheduledFrames: UInt64

    public init(scheduledPackets: UInt64, scheduledFrames: UInt64) {
        self.scheduledPackets = scheduledPackets
        self.scheduledFrames = scheduledFrames
    }
}

/// Native Zig audio executor with a Swift asynchronous notification adapter.
public actor SpiceAudioPlaybackSink {
    public nonisolated let events: AsyncStream<SpiceAudioPlaybackSinkEvent>
    private let continuation: AsyncStream<SpiceAudioPlaybackSinkEvent>.Continuation
    private let maximum: UInt32
    private let interval: UInt32
    private var lease: ZigAudioLease?
    private var task: Task<Void, Never>?
    private var consumption: Task<Void, Never>?
    private var running = false
    private var retiredPackets: UInt64 = 0
    private var retiredFrames: UInt64 = 0

    public init(maximumQueuedMilliseconds: UInt32 = 500, delayReportIntervalMilliseconds: UInt32 = 50) {
        precondition(delayReportIntervalMilliseconds > 0)
        maximum = maximumQueuedMilliseconds
        interval = delayReportIntervalMilliseconds
        let pipe = AsyncStream.makeStream(of: SpiceAudioPlaybackSinkEvent.self, bufferingPolicy: .bufferingNewest(32))
        events = pipe.stream
        continuation = pipe.continuation
    }
    deinit { task?.cancel(); consumption?.cancel(); continuation.finish() }

    public func start(session: SpiceSession) throws(SpiceAudioPlaybackSinkError) {
        guard lease == nil else { throw .alreadyRunning }
        guard maximum > 0 else { throw .invalidConfiguration("invalid queue or delay interval") }
        do { lease = try ZigAudioLease(runtime: session.desktop.runtime, recording: false, maximum: maximum, interval: interval) }
        catch { throw .audioEngine(String(describing: error)) }
        // Preserve the public stream's single-consumer behavior: this service
        // consumes its notifications while the Zig route executes native work.
        let input = session.playbackEvents
        consumption = Task {
            for await _ in input { if Task.isCancelled { return } }
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.drain()
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
            }
        }
    }
    public func stop() {
        task?.cancel(); task = nil
        consumption?.cancel(); consumption = nil
        lease?.join()
        let totals = statistics()
        retiredPackets = totals.scheduledPackets
        retiredFrames = totals.scheduledFrames
        lease = nil
        if running { continuation.yield(.stopped); running = false }
    }
    public func statistics() -> SpiceAudioPlaybackSinkStatistics {
        var native = SpiceZigAudioStatistics()
        if let lease { _ = spice_zig_audio_statistics(lease.raw, &native) }
        return SpiceAudioPlaybackSinkStatistics(
            scheduledPackets: retiredPackets &+ native.scheduled_packets,
            scheduledFrames: retiredFrames &+ native.scheduled_frames)
    }
    private func drain() {
        guard let lease else { return }
        var event = SpiceZigAudioEvent()
        while spice_zig_audio_next(lease.raw, &event) == 1 {
            switch event.kind {
            case 1:
                running = true
                continuation.yield(.started(.init(channels: Int(event.channels), format: .signed16LittleEndian, sampleRate: Int(event.frequency))))
            case 2: running = false; continuation.yield(.stopped)
            case 3: continuation.yield(.muteChanged(event.muted != 0))
            case 5: continuation.yield(.overflowResynchronized(droppedMilliseconds: event.milliseconds))
            case 6: continuation.yield(.oversizedPacketDropped(milliseconds: event.milliseconds))
            case 7: continuation.yield(.underrun)
            case 8:
                let reason = event.error_category.map(String.init(cString:)) ?? "native audio failure"
                let failure: SpiceAudioPlaybackSinkError
                switch reason {
                case "InvalidAudioConfiguration", "InvalidAudioCapacity", "InvalidLimits": failure = .invalidConfiguration(reason)
                case "InvalidSize", "MisalignedPCM", "AudioStopped": failure = .invalidPacket(reason)
                default: failure = .audioEngine(reason)
                }
                continuation.yield(.failed(failure))
            default: break
            }
        }
    }
}
