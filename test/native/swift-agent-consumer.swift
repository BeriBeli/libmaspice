import Foundation
import SwiftSpice
func announce(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }
@main struct Consumer {
    static func main() async throws {
        let args = CommandLine.arguments
        let session = SpiceSession()
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false, pasteboardSynchronizationEnabled: false, maximumFileBytes: 128)
        var layouts = manager.displayConfigurationEvents.makeAsyncIterator()
        var support = manager.displayConfigurationSupportEvents.makeAsyncIterator()
        var files = manager.fileTransferEvents.makeAsyncIterator()
        for run in 0..<2 {
            _ = try await session.connect(endpoint: .init(host: "127.0.0.1", port: UInt16(args[1 + run])!), credentials: .init(password: "synthetic-test"))
            announce("ready \(run)")
            var incoming = session.agentEvents.makeAsyncIterator()
            while let event = await incoming.next() {
                if case let .message(message) = event, message.type == 6 { break }
            }
            try await manager.start(session: session)
            do { try await manager.start(session: session); preconditionFailure("duplicate Agent start") }
            catch SpiceClipboardError.alreadyRunning { }
            while let current = await support.next() { if current.hasExplicitPeerCapabilities && current.agentConnected { break } }
            await manager.publish("disabled synthetic publication")
            await manager.synchronizePasteboard()
            do { try await manager.requestResolution(width: 0, height: 480); preconditionFailure("invalid resolution") }
            catch SpiceDisplayConfigurationError.invalidDimensions { }
            try await manager.requestResolution(width: 640, height: 480)
            while let layout = await layouts.next() { if case .acknowledged = layout { break } }
            do { _ = try await manager.sendFile(at: URL(filePath: args[4])); preconditionFailure("oversized file") }
            catch SpiceFileTransferError.fileTooLarge(let actual, let maximum) { precondition(actual == 256 && maximum == 128) }
            let id = try await manager.sendFile(at: URL(filePath: args[3]), name: "fixture.bin")
            precondition(id.rawValue == UInt32(run + 1))
            while let event = await files.next() {
                if case .completed(id: id) = event { break }
                if case .failed = event { preconditionFailure("file transfer failed") }
            }
            let waiter = Task { await manager.waitForSessionReconnectBoundary() }
            waiter.cancel(); await waiter.value
            await session.disconnect()
            await manager.waitForSessionReconnectBoundary()
            await manager.stop()
            announce("stopped \(run)")
        }
        let metrics = await manager.diagnosticsSnapshot()
        precondition(metrics.inboundCapabilityAnnouncements == 2)
        precondition(metrics.inboundMonitorReplies == 2)
        precondition(metrics.capabilityAnnouncementsSent >= 2)
        precondition(metrics.peerClipboardByDemandCapability == true)
        announce("Swift Agent late start, policy, layout, file limits, reconnect boundary and metrics passed")
    }
}
