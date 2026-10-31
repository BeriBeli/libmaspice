import Dispatch
import Foundation
import SwiftSpice

func announce(_ value: String) {
    FileHandle.standardOutput.write(Data((value + "\n").utf8))
}
func command() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            _ = FileHandle.standardInput.readData(ofLength: 1)
            continuation.resume()
        }
    }
}
func checkPixels(_ frame: SpiceFrame, _ blue: UInt8) {
    precondition(frame.width == 8 && frame.height == 8 && frame.bytesPerRow == 32)
    let expected = Data((0..<64).flatMap { _ in [blue, 0, 0, 255] })
    precondition(frame.pixels == expected, "expected blue \(blue); observed \(Array(frame.pixels.prefix(8)))")
}

@main struct Consumer {
    static func main() async throws {
        let ports = CommandLine.arguments.dropFirst().map { UInt16($0)! }
        precondition(ports.count == 4)
        let frame = try await exercise(ports)
        // No Session/Source/subscription remains. Data and frame leases continue
        // to own immutable native storage across arbitrary reader threads.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { checkPixels(frame, 0x11) } }
        }
        var mutated = frame.pixels
        mutated[0] = 0xff
        mutated.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in bytes[1] = 0xfe }
        checkPixels(frame, 0x11)
        let bytes = frame.pixels
        precondition(bytes.count == 256)
        announce("Swift reconnect, cancellation, demand, input and retained pixels passed")
    }

    static func exercise(_ ports: [UInt16]) async throws -> SpiceFrame {
        let session = SpiceSession()
        let subscription = session.desktop.subscribe(surface: .surface(displayChannelID: 0, surfaceID: 7))
        subscription.setDemand(.visible)
        defer { subscription.cancel() }
        var iterator = subscription.updates.makeAsyncIterator()
        var retained: SpiceFrame?
        for run in 0..<2 {
            if run == 1 {
                do {
                    _ = try await session.connect(endpoint: SpiceEndpoint(host: "127.0.0.1", port: ports[1]),
                                                  credentials: SpiceCredentials(password: "synthetic-test"))
                    preconditionFailure("rejected ticket succeeded")
                } catch SpiceError.authenticationFailed { }
            }
            let info = try await session.connect(endpoint: SpiceEndpoint(host: "127.0.0.1", port: ports[run == 0 ? 0 : 2]),
                                                 credentials: SpiceCredentials(password: "synthetic-test"))
            precondition(info.sessionID == 0x1234 && info.channels.contains { $0.type == 2 })
            do {
                _ = try await session.connect(endpoint: SpiceEndpoint(host: "127.0.0.1", port: 1), credentials: SpiceCredentials())
                preconditionFailure("duplicate connection succeeded")
            } catch SpiceError.alreadyConnected { }
            announce("ready \(run)")
            try await session.send(.mouseMotion(dx: -2, dy: 4))
            var found = false
            while let snapshot = await iterator.next() {
                guard let update = snapshot.frame else { continue }
                precondition(update.revision.surface.surfaceID == 7)
                checkPixels(update.frame, run == 0 ? 0x11 : 0x22)
                if run == 0 { retained = update.frame }
                else { checkPixels(retained!, 0x11) }
                found = true
                break
            }
            precondition(found)
            await session.disconnect()
            var cleared = false
            while let snapshot = await iterator.next() {
                if snapshot.frame == nil { cleared = true; break }
            }
            precondition(cleared)
            announce("stopped \(run)")
        }
        let cancelled = session.desktop.subscribe()
        let consumer = Task { for await _ in cancelled.updates {} }
        consumer.cancel()
        await consumer.value
        cancelled.cancel()
        let connection = Task {
            try await session.connect(endpoint: SpiceEndpoint(host: "127.0.0.1", port: ports[3]),
                                      credentials: SpiceCredentials(password: "synthetic-test"))
        }
        announce("connecting")
        await command()
        connection.cancel()
        do { _ = try await connection.value; preconditionFailure("cancelled connect succeeded") }
        catch SpiceError.cancelled { }
        await session.disconnect()
        // Failed/reset state must be reusable after the cancelled Link read.
        do {
            _ = try await session.connect(endpoint: SpiceEndpoint(host: "127.0.0.1", port: 0), credentials: SpiceCredentials())
            preconditionFailure("invalid endpoint succeeded")
        } catch SpiceError.alreadyConnected { preconditionFailure("cancellation did not join") }
        catch { }
        return retained!
    }
}
