import CSpiceZig
import Foundation

public enum SpiceAudioCaptureSourceError: Error, Sendable, Equatable, CustomStringConvertible {
    case alreadyRunning
    case invalidConfiguration(String)
    case audioEngine(String)
    case conversion(String)
    case session(SpiceError)

    public var description: String {
        switch self {
        case .alreadyRunning:
            "audio capture source is already running"
        case let .invalidConfiguration(reason):
            "invalid record configuration: \(reason)"
        case let .audioEngine(reason):
            "audio capture engine failed: \(reason)"
        case let .conversion(reason):
            "audio conversion failed: \(reason)"
        case let .session(error):
            "record channel failed: \(error)"
        }
    }
}

public enum SpiceAudioCaptureSourceEvent: Sendable, Equatable {
    case started(SpiceRecordConfiguration)
    case stopped
    case overflowDropped(milliseconds: UInt32)
    case volumeChanged([UInt16])
    case muteChanged(Bool)
    case failed(SpiceAudioCaptureSourceError)
}

/// The app supplies microphone usage declarations and consent before starting.
public actor SpiceAudioCaptureSource {
    public nonisolated let events: AsyncStream<SpiceAudioCaptureSourceEvent>
    private let continuation: AsyncStream<SpiceAudioCaptureSourceEvent>.Continuation
    private let maximum: UInt32
    private var lease: ZigAudioLease?
    private var task: Task<Void, Never>?
    private var consumption: Task<Void, Never>?
    private var running = false

    public init(maximumQueuedMilliseconds: UInt32 = 500) {
        maximum = maximumQueuedMilliseconds
        let pipe = AsyncStream.makeStream(of: SpiceAudioCaptureSourceEvent.self, bufferingPolicy: .bufferingNewest(32))
        events = pipe.stream; continuation = pipe.continuation
    }
    deinit { task?.cancel(); consumption?.cancel(); continuation.finish() }
    public func start(session: SpiceSession) throws(SpiceAudioCaptureSourceError) {
        guard lease == nil else { throw .alreadyRunning }
        guard maximum > 0 else { throw .invalidConfiguration("invalid queue duration") }
        do { lease = try ZigAudioLease(runtime: session.desktop.runtime, recording: true, maximum: maximum, interval: 50) }
        catch { throw .audioEngine(String(describing: error)) }
        // Preserve the public stream's single-consumer behavior: this service
        // consumes its notifications while the Zig route executes native work.
        let input = session.recordEvents
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
        consumption?.cancel(); consumption = nil; lease = nil
        if running { continuation.yield(.stopped); running = false }
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
            case 4:
                let volumes = withUnsafeBytes(of: event.volume) { Array($0.bindMemory(to: UInt16.self).prefix(Int(event.volume_count))) }
                continuation.yield(.volumeChanged(volumes))
            case 5: continuation.yield(.overflowDropped(milliseconds: event.milliseconds))
            case 8:
                let reason = event.error_category.map(String.init(cString:)) ?? "native audio failure"
                let failure: SpiceAudioCaptureSourceError
                switch reason {
                case "InvalidAudioConfiguration", "InvalidAudioCapacity", "InvalidLimits": failure = .invalidConfiguration(reason)
                case "AudioInputFormatChanged", "AudioInvalidInputStorage", "AudioConversionFailed", "AudioInvalidOutputStorage": failure = .conversion(reason)
                case "AudioStreamChanged", "ConnectionClosed", "ConnectionFailed", "Cancelled", "Timeout": failure = .session(.protocolError(reason))
                default: failure = .audioEngine(reason)
                }
                continuation.yield(.failed(failure))
            default: break
            }
        }
    }
}
