import CSpiceZig
import Foundation

extension ZigRuntime {
    func run(endpoint: SpiceEndpoint, credentials: SpiceCredentialStorage, streams: ZigEventStreams,
             connected: @escaping @Sendable (Result<SpiceSessionInfo, SpiceError>) -> Void) async {
        await withCheckedContinuation { finished in
            receiveQueue.async { [self] in
                let status = connect(endpoint: endpoint, credentials: credentials)
                if status == 0 {
                    let info = bootstrap()
                    if case .failure = info { spice_zig_desktop_cancel(raw) }
                    if case let .success(value) = info, value.agentConnected {
                        streams.agent.sendLifecycle(.connected)
                    }
                    connected(info)
                } else {
                    spice_zig_desktop_cancel(raw)
                    connected(.failure(zigError(status)))
                }
                while true {
                    var event: OpaquePointer?
                    let result = spice_zig_desktop_next(raw, &event)
                    guard result == 1, let event else {
                        if result < 0 {
                            fail(zigError(result))
                            streams.session.send(.failed(zigError(result)))
                        }
                        break
                    }
                    let observed = spice_zig_source_observe(source, event)
                    if observed < 0 { fail(.protocolError("desktop source (\(observed))")) }
                    let audioObserved = spice_zig_audio_route_observe(audioRoute, event)
                    if audioObserved < 0 { fail(.protocolError("audio event route (\(audioObserved))")) }
                    let agentObserved = spice_zig_agent_route_observe(agentRoute, event)
                    if agentObserved < 0 { fail(.protocolError("agent event route (\(agentObserved))")) }
                    let usbObserved = spice_zig_usb_route_observe(usbRoute, event)
                    if usbObserved < 0 { fail(.protocolError("USB event route (\(usbObserved))")) }
                    let webDAVObserved = spice_zig_webdav_route_observe(webDAVRoute, event)
                    if webDAVObserved < 0 { fail(.protocolError("WebDAV event route (\(webDAVObserved))")) }
                    streams.observe(event, runtime: self, usbHandled: usbObserved == 1, webDAVHandled: webDAVObserved == 1)
                    spice_zig_desktop_event_destroy(event)
                }
                spice_zig_desktop_join(raw)
                finished.resume()
            }
        }
    }

    func send(_ operation: @escaping @Sendable (ZigRuntime) -> Int32) async -> Int32 {
        await withCheckedContinuation { continuation in
            sendQueue.async { [self] in continuation.resume(returning: operation(self)) }
        }
    }

    private func connect(endpoint: SpiceEndpoint, credentials: SpiceCredentialStorage) -> Int32 {
        let kind: UInt8
        let certificates: [Data]
        let serverName: String?
        let subject: String?
        switch endpoint.tlsPolicy {
        case nil: kind = 0; certificates = []; serverName = nil; subject = nil
        case .system: kind = 1; certificates = []; serverName = nil; subject = nil
        case let .customCertificateAuthority(values, name):
            kind = 2; certificates = values; serverName = name; subject = nil
        case let .virtViewerCertificateAuthority(values, expected):
            kind = 3; certificates = values; serverName = nil; subject = expected
        case .insecureForTestingOnly: kind = 4; certificates = []; serverName = nil; subject = nil
        }
        // C string APIs cannot represent embedded NUL; reject instead of silently
        // connecting to a truncated host or weakening a caller's TLS identity.
        guard !endpoint.host.utf8.contains(0), !(serverName?.utf8.contains(0) ?? false),
              !(subject?.utf8.contains(0) ?? false) else { return -1 }
        let objects = certificates.map { $0 as NSData }
        let nativeCertificates = objects.map {
            SpiceZigDesktopCertificate(data: $0.bytes.assumingMemoryBound(to: UInt8.self), size: $0.length)
        }
        var secret = credentials.copyPassword()
        defer { secret.resetBytes(in: secret.indices) }
        return withExtendedLifetime(objects) {
            endpoint.host.withCString { host in
                withOptionalCString(serverName) { name in
                    withOptionalCString(subject) { subject in
                        nativeCertificates.withUnsafeBufferPointer { certificates in
                            secret.withUnsafeBytes { bytes in
                                spice_zig_desktop_connect(raw, host, endpoint.port, kind, name, subject,
                                    certificates.baseAddress, certificates.count, 10_000,
                                    bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
                            }
                        }
                    }
                }
            }
        }
    }

    private func bootstrap() -> Result<SpiceSessionInfo, SpiceError> {
        // Every channel lookup is generation-fenced in C. Retry only this
        // read-only snapshot if a migration adopts a new inventory mid-read.
        for _ in 0..<16 {
            var info = SpiceZigDesktopInfo()
            let status = spice_zig_desktop_info(raw, &info)
            guard status == 0 else { return .failure(zigError(status)) }
            var channels: [SpiceChannelDescriptor] = []
            for index in 0..<Int(info.channel_count) {
                var type: UInt8 = 0, id: UInt8 = 0
                guard spice_zig_desktop_channel(raw, info.generation, index, &type, &id) == 0 else { break }
                channels.append(SpiceChannelDescriptor(type: type, id: id))
            }
            if channels.count == Int(info.channel_count) {
                return .success(SpiceSessionInfo(sessionID: info.session_id,
                    supportedMouseModes: info.supported_mouse_modes, currentMouseMode: info.current_mouse_mode,
                    agentConnected: info.agent_connected != 0, channels: channels))
            }
        }
        return .failure(.protocolError("session changed while reading bootstrap"))
    }
}

func withOptionalCString<Result>(_ value: String?,
                                         _ body: (UnsafePointer<CChar>?) -> Result) -> Result {
    if let value { value.withCString(body) } else { body(nil) }
}
