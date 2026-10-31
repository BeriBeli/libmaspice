import CSpiceZig
import Foundation

/// Content-free observations for the VDAgent wire and clipboard state-machine
/// path owned by one manager.
///
/// Counters are cumulative for the lifetime of the manager. Capability flags
/// and last-value fields are the most recent observation in that lifetime.
/// Message payloads, clipboard text, file names, byte counts, endpoint details,
/// and error strings are never retained.
public struct SpiceAgentWireDiagnostics: Sendable, Equatable {
    public internal(set) var capabilityAnnouncementsAttempted: UInt64 = 0
    public internal(set) var capabilityAnnouncementsSent: UInt64 = 0
    public internal(set) var capabilityAnnouncementFailures: UInt64 = 0
    public internal(set) var inboundMessages: UInt64 = 0
    public internal(set) var inboundCurrentProtocolMessages: UInt64 = 0
    public internal(set) var inboundUnexpectedProtocolMessages: UInt64 = 0
    public internal(set) var inboundCapabilityAnnouncements: UInt64 = 0
    public internal(set) var inboundClipboardMessages: UInt64 = 0
    public internal(set) var inboundClipboardDataMessages: UInt64 = 0
    public internal(set) var inboundClipboardGrabMessages: UInt64 = 0
    public internal(set) var inboundClipboardRequestMessages: UInt64 = 0
    public internal(set) var inboundClipboardReleaseMessages: UInt64 = 0
    public internal(set) var inboundMonitorReplies: UInt64 = 0
    public internal(set) var inboundFileTransferMessages: UInt64 = 0
    public internal(set) var inboundOtherMessages: UInt64 = 0
    public internal(set) var inboundDecodeFailures: UInt64 = 0
    /// Latest values from an explicit peer capability announcement, if any.
    public internal(set) var peerLegacyClipboardCapability: Bool?
    public internal(set) var peerClipboardByDemandCapability: Bool?
    public internal(set) var clipboardFailures: UInt64 = 0
    public internal(set) var lastClipboardFailureCategory: SpiceClipboardFailureCategory?
    public internal(set) var lastInboundProtocolID: UInt32?
    public internal(set) var lastInboundMessageType: UInt32?

    public init() {}

    public static let empty = SpiceAgentWireDiagnostics()
}

public actor SpiceAgentManager {
    public static let maximumWireTextBytes = 16 * 1_024 * 1_024 - 4
    public nonisolated let events: AsyncStream<SpiceClipboardEvent>
    public nonisolated let displayConfigurationEvents: AsyncStream<SpiceDisplayConfigurationEvent>
    public nonisolated let displayConfigurationSupportEvents: AsyncStream<SpiceDisplayConfigurationSupport>
    public nonisolated let fileTransferEvents: AsyncStream<SpiceFileTransferEvent>
    private let clipboard: AsyncStream<SpiceClipboardEvent>.Continuation
    private let display: AsyncStream<SpiceDisplayConfigurationEvent>.Continuation
    private let support: AsyncStream<SpiceDisplayConfigurationSupport>.Continuation
    private let files: AsyncStream<SpiceFileTransferEvent>.Continuation
    private var options: SpiceZigAgentOptions
    private let interval: UInt32
    private var lease: ZigAgentLease?
    private var session: SpiceSession?
    private var task: Task<Void, Never>?
    private var consumption: Task<Void, Never>?
    private var nextRequest: UInt64 = 0
    private var nextFileID: UInt32 = 1
    private var pending: [UInt64: CheckedContinuation<Result<ZigFileKey?, ZigAgentFailure>, Never>] = [:]
    private var fileKeys: [UInt32: ZigFileKey] = [:]
    private var retiredDiagnostics = SpiceAgentWireDiagnostics.empty
    private var reportedFailure = false

    public init(maximumTextBytes: Int = SpiceAgentManager.maximumWireTextBytes,
                automaticallySynchronizesPasteboard: Bool = true,
                pasteboardSynchronizationEnabled: Bool = true,
                pollInterval: Duration = .milliseconds(250), maximumConcurrentFileTransfers: Int = 4,
                maximumFileBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024, fileTransferChunkBytes: Int = 16_000) {
        let c = AsyncStream.makeStream(of: SpiceClipboardEvent.self, bufferingPolicy: .bufferingOldest(32))
        events = c.stream; clipboard = c.continuation
        let d = AsyncStream.makeStream(of: SpiceDisplayConfigurationEvent.self, bufferingPolicy: .bufferingNewest(16))
        displayConfigurationEvents = d.stream; display = d.continuation
        let s = AsyncStream.makeStream(of: SpiceDisplayConfigurationSupport.self, bufferingPolicy: .bufferingNewest(4))
        displayConfigurationSupportEvents = s.stream; support = s.continuation
        let f = AsyncStream.makeStream(of: SpiceFileTransferEvent.self, bufferingPolicy: .bufferingNewest(64))
        fileTransferEvents = f.stream; files = f.continuation
        var options = SpiceZigAgentOptions()
        spice_zig_agent_options(&options)
        options.maximum_text_bytes = min(max(0, maximumTextBytes), Self.maximumWireTextBytes)
        options.clipboard_enabled = pasteboardSynchronizationEnabled ? 1 : 0
        options.maximum_concurrent_files = max(1, maximumConcurrentFileTransfers)
        options.maximum_file_bytes = maximumFileBytes
        options.file_chunk_bytes = min(max(1, fileTransferChunkBytes), 16_000)
        self.options = options
        let components = max(pollInterval, .milliseconds(10)).components
        let ms = Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
        interval = automaticallySynchronizesPasteboard ? UInt32(min(Double(UInt32.max), ms.rounded(.up))) : 0
    }
    deinit {
        task?.cancel(); consumption?.cancel()
        clipboard.finish(); display.finish(); support.finish(); files.finish()
        for continuation in pending.values { continuation.resume(returning: .failure(.init(reason: "Cancelled"))) }
    }
    public func start(session: SpiceSession) async throws(SpiceClipboardError) {
        guard lease == nil else { throw .alreadyRunning }
        do { lease = try ZigAgentLease(runtime: session.desktop.runtime, options: options, interval: interval, firstFileID: nextFileID) }
        catch {
            if let failure = error as? ZigAgentFailure, failure.reason == "AgentAlreadyAttached" { throw .alreadyRunning }
            throw .transport(.protocolError(String(describing: error)))
        }
        self.session = session
        reportedFailure = false
        let input = session.agentEvents
        consumption = Task { for await _ in input { if Task.isCancelled { return } } }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.drain()
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
            }
        }
    }
    public func stop() async {
        task?.cancel(); task = nil
        consumption?.cancel(); consumption = nil
        lease?.join()
        drain()
        retiredDiagnostics = diagnosticsSnapshot()
        if let lease { nextFileID = spice_zig_agent_runner_next_file_id(lease.raw) }
        lease = nil; session = nil; fileKeys.removeAll()
        finishPending(.init(reason: "Cancelled"))
    }
    public func waitForSessionReconnectBoundary() async {
        guard let session, let lease else { return }
        guard await session.waitForCurrentConnectionEnd() else { return }
        guard self.lease === lease, !Task.isCancelled else { return }
        _ = await perform(cancellable: true) { spice_zig_agent_runner_barrier(lease.raw, $0) }
    }
    public func synchronizePasteboard() async {
        guard let lease, options.clipboard_enabled != 0 else { return }
        if case let .failure(error) = await perform({ spice_zig_agent_runner_synchronize(lease.raw, $0) }) {
            clipboard.yield(.failed(clipboardError(error.reason)))
        }
    }
    public func publish(_ text: String) async {
        guard options.clipboard_enabled != 0 else { return }
        guard let lease else {
            do { _ = try await SpicePasteboardBridge.write(text: text) }
            catch { clipboard.yield(.failed(error)) }
            return
        }
        let status = await lease.publish(text)
        guard self.lease === lease else { return }
        guard status == 0 else {
            clipboard.yield(.failed(clipboardError("native publication (\(status))")))
            return
        }
        let result = await perform { spice_zig_agent_runner_barrier(lease.raw, $0) }
        if case let .failure(error) = result { clipboard.yield(.failed(clipboardError(error.reason))) }
    }

    public func setPasteboardSynchronizationEnabled(_ enabled: Bool) async {
        options.clipboard_enabled = enabled ? 1 : 0
        guard let lease else { return }
        let code = spice_zig_agent_runner_enable_clipboard(lease.raw, enabled ? 1 : 0)
        guard code == 0 else { clipboard.yield(.failed(.transport(.protocolError("clipboard policy (\(code))")))); return }
        _ = await perform { spice_zig_agent_runner_barrier(lease.raw, $0) }
        if enabled { await synchronizePasteboard() }
    }
    public func requestResolution(width: Int, height: Int) async throws(SpiceDisplayConfigurationError) {
        guard width > 0, height > 0, UInt32(exactly: width) != nil, UInt32(exactly: height) != nil else {
            throw .invalidDimensions(width: width, height: height)
        }
        try await requestDisplayConfiguration(.init(width: width, height: height))
    }
    public func requestDisplayConfiguration(_ configuration: SpiceDisplayConfiguration) async throws(SpiceDisplayConfigurationError) {
        guard let lease else { throw .agentManagerNotRunning }
        let native = configuration.monitors.map { SpiceZigRequestedMonitor(id: Int64($0.id), x: Int64($0.x), y: Int64($0.y), width: Int64($0.width), height: Int64($0.height)) }
        let result = await perform { request in
            native.withUnsafeBufferPointer { spice_zig_agent_runner_request_display(lease.raw, request, $0.baseAddress, $0.count) }
        }
        if case let .failure(error) = result { throw displayError(error.reason) }
    }
    public func sendFile(at source: URL, name: String? = nil) async throws(SpiceFileTransferError) -> SpiceFileTransferID {
        guard let lease else { throw .agentManagerNotRunning }
        guard source.isFileURL else { throw .invalidFile("source must be a file URL") }
        let path = source.path(), filename = name ?? source.lastPathComponent
        let result = await perform { request in
            path.utf8CString.withUnsafeBytes { path in
                filename.utf8CString.withUnsafeBytes { name in
                    spice_zig_agent_runner_send_file(lease.raw, request, path.bindMemory(to: UInt8.self).baseAddress, path.count - 1, name.bindMemory(to: UInt8.self).baseAddress, name.count - 1)
                }
            }
        }
        switch result {
        case let .success(key?): return SpiceFileTransferID(rawValue: key.id)
        case .success(nil): throw .invalidAgentResponse("missing file handle")
        case let .failure(error): throw fileError(error)
        }
    }
    public func cancelFileTransfer(_ id: SpiceFileTransferID) async {
        guard let lease, let key = fileKeys[id.rawValue] else { return }
        let result = await perform { spice_zig_agent_runner_cancel_file(lease.raw, $0, key.native) }
        if case let .failure(error) = result { files.yield(.failed(id: id, fileError(error))) }
    }
    private func perform(cancellable: Bool = false, _ submit: (UInt64) -> Int32) async -> Result<ZigFileKey?, ZigAgentFailure> {
        guard lease != nil else { return .failure(.init(reason: "AgentUnavailable")) }
        precondition(nextRequest < UInt64.max, "agent request identity exhausted")
        nextRequest += 1
        let request = nextRequest
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !cancellable || !Task.isCancelled else {
                    continuation.resume(returning: .failure(.init(reason: "Cancelled")))
                    return
                }
                pending[request] = continuation
                let status = submit(request)
                if status != 0 {
                    pending.removeValue(forKey: request)?.resume(returning: .failure(.init(reason: "native request (\(status))")))
                }
            }
        } onCancel: {
            if cancellable { Task { await self.cancelPending(request) } }
        }
    }
    private func cancelPending(_ request: UInt64) {
        pending.removeValue(forKey: request)?.resume(returning: .failure(.init(reason: "Cancelled")))
    }
    private func finishPending(_ error: ZigAgentFailure) {
        let work = pending; pending.removeAll()
        for continuation in work.values { continuation.resume(returning: .failure(error)) }
    }
}

@available(*, deprecated, renamed: "SpiceAgentManager")
public typealias SpiceClipboardManager = SpiceAgentManager

extension SpiceAgentManager {
    private func drain() {
        guard let lease else { return }
        var event: OpaquePointer?
        while spice_zig_agent_runner_next(lease.raw, &event) == 1, let value = event {
            defer { spice_zig_agent_runner_event_destroy(value) }
            var info = SpiceZigAgentRunnerEventInfo()
            precondition(spice_zig_agent_runner_event_info(value, &info) == 0)
            switch info.kind {
            case 1:
                if let agent = spice_zig_agent_runner_event_agent(value) { receive(agent) }
            case 2:
                let reason = spice_zig_agent_runner_event_error(value).map(String.init(cString:)) ?? "AgentUnavailable"
                var actual: UInt64 = 0, maximum: UInt64 = 0
                _ = spice_zig_agent_runner_event_limits(value, &actual, &maximum)
                let error = ZigAgentFailure(reason: reason, actual: actual, maximum: maximum)
                if let request = pending.removeValue(forKey: info.request) { request.resume(returning: .failure(error)) }
                else { clipboard.yield(.failed(clipboardError(reason))) }
            case 3:
                let key = ZigFileKey(id: info.key.id, incarnation: info.key.incarnation)
                fileKeys[key.id] = key
                pending.removeValue(forKey: info.request)?.resume(returning: .success(key))
            case 4: pending.removeValue(forKey: info.request)?.resume(returning: .success(nil))
            default: break
            }
        }
        let status = spice_zig_agent_runner_status(lease.raw)
        if status < 0, !reportedFailure {
            reportedFailure = true
            let error = ZigAgentFailure(reason: "agent executor (\(status))")
            clipboard.yield(.failed(clipboardError(error.reason)))
            finishPending(error)
        }
    }
    private func receive(_ event: OpaquePointer) {
        var info = SpiceZigAgentEventInfo()
        precondition(spice_zig_agent_event_info(event, &info) == 0)
        let v = withUnsafeBytes(of: info.values) { Array($0.bindMemory(to: UInt32.self)) }
        let w = withUnsafeBytes(of: info.wide) { Array($0.bindMemory(to: UInt64.self)) }
        func text() -> String {
            var count = 0
            guard let bytes = spice_zig_agent_event_data(event, &count) else { return "" }
            return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
        }
        func reason() -> String { spice_zig_agent_event_error(event).map(String.init(cString:)) ?? "AgentUnavailable" }
        switch info.kind {
        case 1:
            switch info.detail {
            case 1: clipboard.yield(.ready)
            case 2: clipboard.yield(.unavailable)
            case 3: clipboard.yield(.guestText(text()))
            case 4: clipboard.yield(.localTextOffered(byteCount: Int(clamping: w[0])))
            case 5: clipboard.yield(.oversizedLocalText(byteCount: Int(clamping: w[0]), maximum: Int(clamping: w[1])))
            default: break
            }
        case 2:
            support.yield(.init(agentConnected: v[0] & 1 != 0, hasExplicitPeerCapabilities: v[0] & 2 != 0,
                supportsMonitorConfiguration: v[0] & 4 != 0, supportsSparseMonitors: v[0] & 8 != 0,
                supportsMonitorPositions: v[0] & 16 != 0))
        case 3:
            var monitors: [SpiceMonitorConfiguration] = []
            for index in 0..<Int(v[0]) {
                var monitor = SpiceZigRequestedMonitor()
                precondition(spice_zig_agent_event_monitor(event, index, &monitor) == 0)
                monitors.append(.init(id: Int(monitor.id), x: Int(monitor.x), y: Int(monitor.y), width: Int(monitor.width), height: Int(monitor.height)))
            }
            let configuration = SpiceDisplayConfiguration(monitors: monitors)
            switch info.detail {
            case 1: display.yield(.queued(configuration))
            case 2: display.yield(.sent(configuration))
            case 3: display.yield(.acknowledged(configuration))
            case 4: display.yield(.rejected(configuration))
            case 5: display.yield(.unsupported(configuration))
            case 6:
                let error = displayError(reason())
                display.yield(monitors.isEmpty ? .protocolFailure(error) : .failed(configuration, error))
            default: break
            }
        case 4:
            let id = SpiceFileTransferID(rawValue: v[0])
            switch info.detail {
            case 1:
                fileKeys[id.rawValue] = ZigFileKey(id: id.rawValue, incarnation: w[0])
                files.yield(.queued(id: id, name: text(), totalBytes: w[2]))
            case 2: files.yield(.awaitingGuestApproval(id: id))
            case 3: files.yield(.progress(id: id, sentBytes: w[1], totalBytes: w[2]))
            case 4: fileKeys.removeValue(forKey: id.rawValue); files.yield(.completed(id: id))
            case 5: fileKeys.removeValue(forKey: id.rawValue); files.yield(.cancelled(id: id))
            case 6:
                if v[1] != 0 { fileKeys.removeValue(forKey: id.rawValue) }
                files.yield(.failed(id: v[1] == 0 ? nil : id, fileError(.init(reason: reason()))))
            default: break
            }
        default: break
        }
    }
    private func clipboardError(_ reason: String) -> SpiceClipboardError {
        switch reason {
        case "InvalidUTF8": .invalidUTF8
        case "PasteboardWriteFailed", "PasteboardUnavailable": .pasteboardWriteFailed
        case "ConnectionClosed", "ConnectionFailed", "TLSFailure", "Cancelled", "Timeout", "AgentUnavailable": .transport(.protocolError(reason))
        default: .invalidAgentMessage(reason)
        }
    }
    private func displayError(_ reason: String) -> SpiceDisplayConfigurationError {
        switch reason {
        case "UnsupportedMonitorConfiguration": .unsupportedByAgent
        case "UnsolicitedMonitorReply": .invalidAgentReply(reason)
        case "AgentUnavailable", "ConnectionClosed", "ConnectionFailed", "Cancelled": .transport(.protocolError(reason))
        default: .invalidLayout(reason)
        }
    }
    private func fileError(_ failure: ZigAgentFailure) -> SpiceFileTransferError {
        switch failure.reason {
        case "AgentUnavailable", "AgentDisconnected", "Cancelled": .agentUnavailable
        case "FileTransferDisabled": .disabledByGuest
        case "TooManyFileTransfers": .tooManyConcurrentTransfers(maximum: options.maximum_concurrent_files)
        case "FileTooLarge": .fileTooLarge(actual: failure.actual, maximum: failure.maximum)
        case "FileReadFailed", "FileTruncated": .localReadFailed(failure.reason)
        case "ConnectionClosed", "ConnectionFailed", "TLSFailure", "Timeout": .transport(.protocolError(failure.reason))
        case "InvalidFileStatus", "UnexpectedFileStatus", "UnsupportedGuestFilePayload", "GuestFileError", "GuestInsufficientSpace", "GuestSessionLocked", "InvalidTransferState", "PrematureFileSuccess", "UnexpectedFileApproval", "UnknownFileTransfer": .invalidAgentResponse(failure.reason)
        default: .invalidFile(failure.reason)
        }
    }
}

extension SpiceAgentManager {
    public func diagnosticsSnapshot() -> SpiceAgentWireDiagnostics {
        var result = retiredDiagnostics
        guard let lease else { return result }
        var native = SpiceZigAgentMetrics()
        guard spice_zig_agent_runner_metrics(lease.raw, &native) == 0 else { return result }
        result.capabilityAnnouncementsAttempted &+= native.capability_attempts
        result.capabilityAnnouncementsSent &+= native.capability_sent
        result.capabilityAnnouncementFailures &+= native.capability_failures
        result.inboundMessages &+= native.inbound
        result.inboundCurrentProtocolMessages &+= native.current_protocol
        result.inboundUnexpectedProtocolMessages &+= native.unexpected_protocol
        result.inboundCapabilityAnnouncements &+= native.capabilities
        result.inboundClipboardMessages &+= native.clipboard
        result.inboundClipboardDataMessages &+= native.data
        result.inboundClipboardGrabMessages &+= native.grab
        result.inboundClipboardRequestMessages &+= native.request
        result.inboundClipboardReleaseMessages &+= native.release
        result.inboundMonitorReplies &+= native.monitor_replies
        result.inboundFileTransferMessages &+= native.files
        result.inboundOtherMessages &+= native.other
        result.inboundDecodeFailures &+= native.decode_failures
        result.clipboardFailures &+= native.clipboard_failures

        if native.has_peer != 0 {
            result.peerLegacyClipboardCapability = native.peer_legacy != 0
            result.peerClipboardByDemandCapability = native.peer_demand != 0
        }
        if native.has_inbound != 0 {
            result.lastInboundProtocolID = native.last_protocol
            result.lastInboundMessageType = native.last_kind
        }
        if native.last_failure != 0 {
            let categories: [SpiceClipboardFailureCategory] = [.agentDisconnected,.clipboardNotReady,.unsolicitedData,.unexpectedType,.oversizedGuestText,.invalidUTF8,.decodeFailure,.encodeFailure,.pasteboardWrite,.transport,.other]
            result.lastClipboardFailureCategory = categories[min(Int(native.last_failure)-1, categories.count-1)]
        }
        return result
    }
}
