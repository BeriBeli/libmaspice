import CSpiceZig
import Dispatch
import Foundation

public actor SpiceSession {
    public nonisolated let desktop: SpiceDesktopSource
    public nonisolated let events: AsyncStream<SpiceSessionEvent>
    public nonisolated let playbackEvents: AsyncStream<SpicePlaybackEvent>
    public nonisolated let recordEvents: AsyncStream<SpiceRecordEvent>
    public nonisolated var agentEvents: AsyncStream<SpiceAgentEvent> {
        AsyncStream(unfolding: { await self.streams.agent.next()?.event })
    }
    public nonisolated let smartcardEvents: AsyncStream<SpiceSmartcardEvent>
    public nonisolated let usbRedirectionPackets: AsyncStream<SpiceUSBRedirectionPacket>
    public nonisolated let webDAVEvents: AsyncStream<SpiceWebDAVEvent>
    private nonisolated let streams: ZigEventStreams
    private let runtime: ZigRuntime
    private var worker: Task<Void, Never>?
    private var nextID: UInt64 = 0
    private var activeID: UInt64?
    private var connecting = false
    private var ready = false
    private var stopping = false
    private var sends: [UInt64: Task<Int32, Never>] = [:]
    private var webDAVServers: [UInt8: ZigWebDAVLease] = [:]
    private var webDAVMonitor: Task<Void, Never>?
    private var usbHosts: [UInt8: ZigUSBLease] = [:]
    private var usbMonitor: Task<Void, Never>?

    public init() {
        // Source must exist before connect so applications can subscribe first.
        // Allocation failure follows Swift's nonthrowing object-init contract.
        let runtime: ZigRuntime
        do { runtime = try ZigResources.runtime() }
        catch { preconditionFailure("desktop runtime initialization failed") }
        self.runtime = runtime
        desktop = SpiceDesktopSource(runtime: runtime)
        let streams = ZigEventStreams()
        self.streams = streams
        events = AsyncStream(unfolding: { await streams.session.next() })
        playbackEvents = streams.playback.stream
        recordEvents = streams.record.stream
        smartcardEvents = streams.smartcard.stream
        usbRedirectionPackets = streams.usb.stream
        webDAVEvents = streams.webdav.stream
    }

    init(runtime: ZigRuntime) {
        self.runtime = runtime
        desktop = SpiceDesktopSource(runtime: runtime)
        let streams = ZigEventStreams()
        self.streams = streams
        events = AsyncStream(unfolding: { await streams.session.next() })
        playbackEvents = streams.playback.stream
        recordEvents = streams.record.stream
        smartcardEvents = streams.smartcard.stream
        usbRedirectionPackets = streams.usb.stream
        webDAVEvents = streams.webdav.stream
    }

    public func connect(endpoint: SpiceEndpoint, credentials: consuming SpiceCredentials)
        async throws(SpiceError) -> SpiceSessionInfo {
        guard worker == nil, sends.isEmpty, !stopping, !connecting else { throw .alreadyConnected }
        guard !Task.isCancelled else { throw .cancelled }
        connecting = true
        defer { connecting = false }
        let video: UInt8 = switch endpoint.videoCodecPolicy {
        case .mjpegOnly: 0
        case .h264AndMJPEG: 1
        case .h265AndMJPEG: 2
        }
        let status = spice_zig_desktop_reset(runtime.raw, video)
        guard status == 0 else { throw zigError(status) }
        runtime.clearFailure()
        spice_zig_diagnostics_reset(runtime.diagnostics.raw)
        let id = allocateID()
        activeID = id
        let storage = credentials.transferStorage()
        let runtime = self.runtime
        let streams = self.streams
        let result: Result<SpiceSessionInfo, SpiceError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                worker = Task { [weak self] in
                    await runtime.run(endpoint: endpoint, credentials: storage, streams: streams) {
                        continuation.resume(returning: $0)
                    }
                    await self?.ended(id: id)
                }
            }
        } onCancel: { spice_zig_desktop_cancel(runtime.raw) }
        switch result {
        case let .success(info):
            guard activeID == id, !stopping, !Task.isCancelled else {
                spice_zig_desktop_cancel(runtime.raw)
                if let worker { await worker.value }
                throw .cancelled
            }
            ready = true
            return info
        case let .failure(error):
            if let worker { await worker.value }
            throw error
        }
    }

    public func disconnect() async {
        guard let worker else {
            // A native terminal event can finish the receiver before sends wake.
            stopping = true
            spice_zig_desktop_cancel(runtime.raw)
            for task in sends.values { _ = await task.value }
            stopping = false
            return
        }
        stopping = true
        ready = false
        spice_zig_desktop_cancel(runtime.raw)
        await worker.value
        for task in sends.values { _ = await task.value }
        stopping = false
    }

    // Wait only for the connection observed on entry; cancellation of this
    // waiter never cancels a live session or follows a subsequent reconnect.
    func waitForCurrentConnectionEnd() async -> Bool {
        guard let observed = activeID else { return !Task.isCancelled }
        while activeID == observed, !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
        }
        return activeID == nil && !Task.isCancelled
    }

    private func ended(id: UInt64) async {
        guard activeID == id else { return }
        ready = false
        webDAVMonitor?.cancel()
        for lease in webDAVServers.values { lease.stop() }
        usbMonitor?.cancel()
        usbMonitor = nil
        for lease in usbHosts.values { lease.stop() }
        for task in sends.values { _ = await task.value }
        usbHosts.removeAll()
        webDAVServers.removeAll()
        webDAVMonitor = nil
        activeID = nil
        worker = nil
    }

    private func allocateID() -> UInt64 {
        precondition(nextID < UInt64.max, "session operation identity exhausted")
        nextID += 1
        return nextID
    }

    private func sendOperation(_ operation: @escaping @Sendable (ZigRuntime) -> Int32)
        async throws(SpiceError) {
        guard ready, !stopping else { throw .protocolError("session is not connected") }
        guard !Task.isCancelled else { throw .cancelled }
        let id = allocateID()
        let runtime = self.runtime
        let task = Task { await runtime.send(operation) }
        sends[id] = task
        let status = await withTaskCancellationHandler { await task.value }
            onCancel: { spice_zig_desktop_cancel(runtime.raw) }
        sends.removeValue(forKey: id)
        if Task.isCancelled { throw .cancelled }
        guard status == 0 else { throw zigError(status) }
    }

    public func diagnosticsSnapshot() async -> SpiceSessionDiagnostics {
        runtime.diagnosticsSnapshot()
    }

    public func send(_ input: SpiceClientInput) async throws(SpiceError) {
        let value = input.native
        try await sendOperation {
            spice_zig_desktop_input($0.raw, 0, value.kind, value.x, value.y, value.display)
        }
    }

    package func beginRecording(timestamp: UInt32) async throws(SpiceError) {
        try await sendOperation { spice_zig_desktop_record($0.raw, 0, 1, timestamp, nil, 0) }
    }
    package func sendRecordedAudio(timestamp: UInt32, pcm: Data) async throws(SpiceError) {
        try await sendOperation { runtime in
            pcm.withUnsafeBytes { bytes in
                spice_zig_desktop_record(runtime.raw, 0, 0, timestamp, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
        }
    }

    public func reportPlaybackDelay(milliseconds: UInt32) async throws(SpiceError) {
        try await sendOperation { spice_zig_desktop_playback_delay($0.raw, 0, milliseconds) }
    }

    public func addSmartcardReader(named name: String) async throws(SpiceError) {
        try await smartcard(kind: 3, reader: UInt32.max, data: Data(name.utf8))
    }
    public func removeSmartcardReader(id: UInt32) async throws(SpiceError) {
        try await smartcard(kind: 4, reader: id)
    }
    public func insertSmartcard(readerID: UInt32, atr: Data) async throws(SpiceError) {
        try await smartcard(kind: 5, reader: readerID, data: atr)
    }
    public func removeSmartcard(readerID: UInt32) async throws(SpiceError) {
        try await smartcard(kind: 6, reader: readerID)
    }
    public func respondToSmartcardAPDU(readerID: UInt32, data: Data) async throws(SpiceError) {
        try await smartcard(kind: 7, reader: readerID, data: data)
    }
    public func sendSmartcardError(readerID: UInt32, code: UInt32) async throws(SpiceError) {
        var little = code.littleEndian
        let data = withUnsafeBytes(of: &little) { Data($0) }
        try await smartcard(kind: 2, reader: readerID, data: data)
    }
    public func completeSmartcardFlush(readerID: UInt32) async throws(SpiceError) {
        try await smartcard(kind: 9, reader: readerID)
    }
    private func smartcard(kind: UInt32, reader: UInt32, data: Data = Data()) async throws(SpiceError) {
        try await sendOperation { runtime in
            data.withUnsafeBytes {
                spice_zig_desktop_smartcard(runtime.raw, 0, kind, reader,
                                           $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
            }
        }
    }
    public func sendUSBRedirectionPacket(channelID: UInt8, data: Data) async throws(SpiceError) {
        try await sendOperation { runtime in
            data.withUnsafeBytes {
                spice_zig_desktop_usb(runtime.raw, channelID, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
            }
        }
    }
    public func attachUSBRedirectionHost(_ host: SpiceUSBRedirectionHost, channelID: UInt8) async throws(SpiceError) {
        guard ready, !stopping else { throw .protocolError("session is not connected") }
        guard usbHosts[channelID] == nil else { throw .protocolError("USB channel already has a backend") }
        let lease = try ZigUSBLease(runtime: runtime, host: host.owner, channel: channelID)
        usbHosts[channelID] = lease
        do { try await sendOperation { _ in spice_zig_usb_ready(lease.raw) } }
        catch {
            if usbHosts[channelID] === lease { usbHosts.removeValue(forKey: channelID) }
            throw error
        }
        if usbMonitor == nil {
            usbMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                    await self?.checkUSBHosts()
                }
            }
        }
    }
    public func attachUSBDevice(channelID: UInt8, busNumber: UInt8, deviceAddress: UInt8) async throws(SpiceError) {
        try await usbDevice(channel: channelID, attach: true, bus: busNumber, address: deviceAddress)
    }
    public func detachUSBDevice(channelID: UInt8) async throws(SpiceError) {
        try await usbDevice(channel: channelID, attach: false, bus: 0, address: 0)
    }
    private func usbDevice(channel: UInt8, attach: Bool, bus: UInt8, address: UInt8) async throws(SpiceError) {
        guard let lease = usbHosts[channel] else { throw .protocolError("USB channel has no backend") }
        try await sendOperation { _ in
            var native: Int32 = 0
            return spice_zig_usb_device(lease.raw, attach ? 1 : 0, bus, address, &native)
        }
    }
    private func checkUSBHosts() {
        for (channel, lease) in usbHosts {
            var category: UnsafePointer<CChar>?
            var native: Int32 = 0
            let status = spice_zig_usb_status(lease.raw, &category, &native)
            if status < 0 {
                runtime.fail(.protocolError("USB backend: \(category.map { String(cString: $0) } ?? "unknown") (\(native))"))
            }
            if status != 0 { usbHosts.removeValue(forKey: channel) }
        }
    }

    public func attachWebDAVServer(_ server: SpiceWebDAVServer, channelID: UInt8 = 0) throws(SpiceError) {
        guard ready, !stopping else { throw .protocolError("session is not connected") }
        guard webDAVServers[channelID] == nil else { throw .protocolError("WebDAV channel already has a backend") }
        webDAVServers[channelID] = try ZigWebDAVLease(runtime: runtime, server: server.owner, channel: channelID)
        if webDAVMonitor == nil {
            webDAVMonitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                    await self?.checkWebDAVServers()
                }
            }
        }
    }
    private func checkWebDAVServers() {
        for (channel, lease) in webDAVServers {
            var category: UnsafePointer<CChar>?
            let status = spice_zig_webdav_status(lease.raw, &category)
            if status < 0 {
                runtime.fail(.protocolError("WebDAV backend: \(category.map { String(cString: $0) } ?? "unknown")"))
            }
            if status != 0 { webDAVServers.removeValue(forKey: channel) }
        }
    }

    public func sendWebDAVResponse(clientID: Int64, data: Data, channelID: UInt8 = 0) async throws(SpiceError) {
        try await sendOperation { runtime in
            data.withUnsafeBytes {
                spice_zig_desktop_webdav(runtime.raw, channelID, clientID, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
            }
        }
    }

    deinit {
        webDAVMonitor?.cancel()
        for lease in webDAVServers.values { lease.stop() }
        usbMonitor?.cancel()
        for lease in usbHosts.values { lease.stop() }
        spice_zig_desktop_cancel(runtime.raw)
        streams.finish()
        // The worker and outstanding sends retain Runtime until they return;
        // its destructor joins native work before destroying Source and Desktop.
    }
}

func zigError(_ status: Int32) -> SpiceError {
    switch status {
    case -31: .cancelled
    case -37, -39: .authenticationFailed("native authentication (\(status))")
    case -30, -32, -33, -34, -36: .connectionFailed("native transport (\(status))")
    default: .protocolError("native operation (\(status))")
    }
}

extension SpiceClientInput {
    var native: (kind: UInt8, x: Int32, y: Int32, display: UInt8) {
        switch self {
        case let .keyDown(code): (0, Int32(bitPattern: code), 0, 0)
        case let .keyUp(code): (1, Int32(bitPattern: code), 0, 0)
        case let .lockModifiers(value): (2, Int32(value), 0, 0)
        case let .mouseMotion(x, y): (3, x, y, 0)
        case let .mousePosition(x, y, display): (4, Int32(bitPattern: x), Int32(bitPattern: y), display)
        case let .mousePress(button): (5, Int32(button.rawValue), 0, 0)
        case let .mouseRelease(button): (6, Int32(button.rawValue), 0, 0)
        }
    }
}
