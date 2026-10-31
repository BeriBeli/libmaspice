import Foundation
import SwiftSpice

func announce(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
@main struct Consumer {
    static func main() async throws {
        let ports = CommandLine.arguments.dropFirst().map { UInt16($0)! }
        let session = SpiceSession()
        for run in 0..<2 {
            var host: SpiceUSBRedirectionHost? = try .init(maximumBufferedBytes: 4096, maximumSpicePacketBytes: 8)
            let packets = await host!.initialPackets()
            precondition(packets.count == 10 && packets.allSatisfy { $0.count == 8 })
            let hello = packets.reduce(into: Data()) { $0.append($1) }
            precondition(hello.count == 80)
            let replies = try await host!.receiveFromGuest(hello.prefix(17))
            precondition(replies.isEmpty)
            do { _ = try await host!.pumpEvents(timeoutMilliseconds: 101); preconditionFailure("unbounded pump") }
            catch SpiceUSBRedirectionHostError.invalidArgument { }
            _ = try await session.connect(endpoint: .init(host: "127.0.0.1", port: ports[run]), credentials: .init(password: "synthetic-test"))
            do { try await session.attachUSBRedirectionHost(host!, channelID: 0); preconditionFailure("missing channel") }
            catch SpiceError.protocolError { }
            try await session.attachUSBRedirectionHost(host!, channelID: 7)
            do { try await session.attachUSBRedirectionHost(host!, channelID: 7); preconditionFailure("duplicate backend") }
            catch SpiceError.protocolError { }
            if run == 1 { host = nil }
            announce("attached \(run)")
            precondition(readLine() == "done")
            // Also proves >16 incoming packets did not overflow an unused stream.
            try await session.detachUSBDevice(channelID: 7)
            await session.disconnect()
            if let host {
                _ = try await host.pumpEvents()
                _ = try await host.detachDevice()
            }
            announce("stopped \(run)")
        }
        announce("Swift USB existing parser state, retained host, ordered replies and reconnect passed")
    }
}
