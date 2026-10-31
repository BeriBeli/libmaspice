import CSpiceZig
import Foundation

// AsyncStream is the public Swift consumption boundary. Keep its established
// buffering/overflow contracts; native state machines and Source run before it.
final class ZigEventStreams: Sendable {
    let session = SpiceSessionEventMailbox()
    let agent = SpiceAgentEventMailbox()
    let playback = AsyncStream.makeStream(of: SpicePlaybackEvent.self, bufferingPolicy: .bufferingNewest(32))
    let record = AsyncStream.makeStream(of: SpiceRecordEvent.self, bufferingPolicy: .bufferingOldest(32))
    let smartcard = AsyncStream.makeStream(of: SpiceSmartcardEvent.self, bufferingPolicy: .bufferingOldest(64))
    let usb = AsyncStream.makeStream(of: SpiceUSBRedirectionPacket.self, bufferingPolicy: .bufferingOldest(16))
    let webdav = AsyncStream.makeStream(of: SpiceWebDAVEvent.self, bufferingPolicy: .bufferingOldest(64))

    func finish() {
        session.finish(); agent.finish()
        playback.continuation.finish(); record.continuation.finish()
        smartcard.continuation.finish(); usb.continuation.finish(); webdav.continuation.finish()
    }

    func offer<Element: Sendable>(_ value: Element, to continuation: AsyncStream<Element>.Continuation,
                        runtime: ZigRuntime, name: String) {
        if case .dropped = continuation.yield(value) {
            runtime.fail(.protocolError("\(name) event queue overflow"))
        }
    }

    func observe(_ event: OpaquePointer, runtime: ZigRuntime, usbHandled: Bool = false, webDAVHandled: Bool = false) {
        var info = SpiceZigDesktopEventMetadata()
        precondition(spice_zig_desktop_event_metadata(event, &info) == 0)
        let v = withUnsafeBytes(of: info.values) { Array($0.bindMemory(to: UInt32.self)) }
        let w = withUnsafeBytes(of: info.wide) { Array($0.bindMemory(to: UInt64.self)) }
        func data() -> Data {
            var count = 0
            let bytes = spice_zig_desktop_event_data(event, &count)
            return count == 0 ? Data() : Data(bytes: bytes!, count: count)
        }
        func errorName() -> String {
            spice_zig_desktop_event_error(event).map(String.init(cString:)) ?? "native session failure"
        }
        switch info.kind {
        case 2:
            playback.continuation.yield(.stopped)
            offer(.stopped, to: record.continuation, runtime: runtime, name: "Record")
            agent.sendLifecycle(.disconnected(errorCode: 0))
            if let error = runtime.failure { session.send(.failed(error)) }
            session.send(.disconnected)
        case 3:
            let failure: SpiceError
            if info.detail == 1 || info.detail == 2 {
                let status = Int32(bitPattern: v[2])
                failure = .videoCodecUnavailable(SpiceVideoCodecFailure(
                    codec: v[0] == 0 ? .h264 : .h265,
                    reason: info.detail == 1
                        ? .hardwareUnavailable(status: v[1] == 0 ? nil : status)
                        : .unsupportedFormat(status: status)))
            } else { failure = .protocolError(errorName()) }
            session.send(.failed(failure))
        case 4:
            switch info.detail {
            case 2: agent.sendLifecycle(.connected, connectionGeneration: w[1], sessionLifecycleID: w[2])
            case 3: agent.sendLifecycle(.disconnected(errorCode: v[0]), connectionGeneration: w[1], sessionLifecycleID: w[2])
            case 4:
                if agent.send(.message(SpiceAgentMessage(protocolID: v[0], type: v[1], opaque: w[0], data: data())),
                              connectionGeneration: w[1]) == .full {
                    runtime.fail(.protocolError("Agent event queue overflow"))
                }
            default: break
            }
        case 5 where info.detail == 4:
            var monitors: [SpiceGuestMonitor] = []
            for index in 0..<Int(v[1]) {
                var monitor = SpiceZigMonitor()
                precondition(spice_zig_desktop_event_monitor(event, index, &monitor) == 0)
                monitors.append(SpiceGuestMonitor(id: monitor.id, surfaceID: monitor.surface,
                    x: monitor.x, y: monitor.y, width: monitor.width, height: monitor.height, flags: monitor.flags))
            }
            session.send(.displayConfiguration(SpiceGuestDisplayConfiguration(channelID: info.channel_id,
                maximumAllowed: v[0] == 0 ? nil : UInt16(v[0]), monitors: monitors)))
        case 6:
            var count = 0
            let bytes = spice_zig_desktop_event_migration_subject(event, &count)
            let subject = v[5] == 0 ? nil : String(decoding: count == 0 ? Data() : Data(bytes: bytes!, count: count), as: UTF8.self)
            let offer = SpiceMigrationOffer(id: w[0], destination: SpiceMigrationDestination(
                host: String(decoding: data(), as: UTF8.self), port: v[1] == 0 ? nil : UInt16(v[1]),
                securePort: v[2] == 0 ? nil : UInt16(v[2]), certificateSubject: subject),
                mode: v[3] == 0 ? .semiSeamless : v[3] == 1 ? .seamless(sourceVersion: v[4]) : .switchHost)
            let value: SpiceMigrationEvent
            switch info.detail {
            case 1: value = .preparing(offer)
            case 2: value = .ready(offer, seamless: v[0] != 0)
            case 3: value = .cancelled(offer)
            case 4: value = .committing(offer)
            case 5: value = .switching(offer)
            case 6: value = .completed(offer)
            default: value = .failed(offer, reason: errorName())
            }
            session.send(.migration(value))
        case 7:
            if info.detail == 3 { session.send(.mouseMotionAcknowledged) }
            else { session.send(.keyboardModifiers(UInt16(v[0]))) }
        case 9:
            let value: SpicePlaybackEvent?
            switch info.detail {
            case 1: value = .modeChanged(multimediaTime: v[0], mode: .raw)
            case 2: value = .started(SpicePlaybackConfiguration(channels: Int(v[0]), format: .signed16LittleEndian, sampleRate: Int(v[2])))
            case 3: value = .packet(SpicePlaybackPacket(multimediaTime: v[0], data: data()))
            case 4: value = .stopped
            case 5: value = .volumeChanged(v[1..<(1 + Int(v[0]))].map(UInt16.init))
            case 6: value = .muteChanged(v[0] != 0)
            case 7: value = .minimumLatencyChanged(milliseconds: v[0])
            default: value = nil
            }
            if let value { playback.continuation.yield(value) }
        case 10:
            let value: SpiceRecordEvent?
            switch info.detail {
            case 2: value = .started(SpiceRecordConfiguration(channels: Int(v[0]), format: .signed16LittleEndian, sampleRate: Int(v[2])))
            case 4: value = .stopped
            case 5: value = .volumeChanged(v[1..<(1 + Int(v[0]))].map(UInt16.init))
            case 6: value = .muteChanged(v[0] != 0)
            default: value = nil
            }
            if let value { offer(value, to: record.continuation, runtime: runtime, name: "Record") }
        case 11:
            let value: SpiceSmartcardEvent
            switch info.detail {
            case 1:
                let bytes = data()
                let capabilities = stride(from: 0, to: bytes.count, by: 4).map { offset in
                    bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
                }
                value = .initialized(SpiceSmartcardInitializationInfo(version: v[0], capabilities: capabilities))
            case 2: value = .operationCompleted(request: SpiceSmartcardRequestType(rawValue: v[0])!, readerID: v[1], errorCode: v[2])
            case 3: value = .apdu(readerID: v[0], data: data())
            default: value = .flushRequested(readerID: v[0])
            }
            offer(value, to: smartcard.continuation, runtime: runtime, name: "Smartcard")
        case 12:
            if usbHandled { return }
            offer(SpiceUSBRedirectionPacket(channelID: info.channel_id, data: data()), to: usb.continuation, runtime: runtime, name: "USB redirection")
        case 13:
            if webDAVHandled && info.detail >= 3 { return }
            let value: SpiceWebDAVEvent
            switch info.detail {
            case 1: value = .initialized(name: String(decoding: data(), as: UTF8.self), opened: v[0] != 0)
            case 2: value = .port(SpiceWebDAVPortEvent(rawValue: UInt8(v[0]))!)
            case 3: value = .request(clientID: Int64(bitPattern: w[0]), data: data())
            default: value = .clientClosed(Int64(bitPattern: w[0]))
            }
            offer(value, to: webdav.continuation, runtime: runtime, name: "WebDAV")
        default: break
        }
    }
}
