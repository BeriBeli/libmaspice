import Foundation
import SwiftSpice

func announce(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
@main struct Consumer {
    static func main() async throws {
        let args = CommandLine.arguments
        let session = SpiceSession()
        let subscription = session.desktop.subscribe(surface: .surface(displayChannelID: 0, surfaceID: 7))
        subscription.setDemand(.visible)
        let expected = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        _ = try await session.connect(endpoint: SpiceEndpoint(host: "127.0.0.1", port: UInt16(args[1])!),
                                      credentials: SpiceCredentials(password: "synthetic-test"))
        announce("ready")
        var received: SpiceFrame?
        for await snapshot in subscription.updates {
            guard let frame = snapshot.frame?.frame, frame.ioSurface != nil else { continue }
            received = frame
            break
        }
        let frame = received!
        precondition(frame.ioSurface!.id != 0 && frame.ioSurface!.bytesPerRow >= 32)
        precondition(frame == frame)
        var before = await session.diagnosticsSnapshot()
        for _ in 0..<1000 where before.mjpegDecodedFrames == 0 {
            try await Task.sleep(for: .milliseconds(1))
            before = await session.diagnosticsSnapshot()
        }
        precondition(before.mjpegDecodedFrames == 1 && before.mjpegIOSurfaceFrames == 1)
        precondition(before.publisherEmittedIOSurfaceFrames == 1 && before.cpuMaterializations == 0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { precondition(frame.pixels == expected) } }
        }
        let after = await session.diagnosticsSnapshot()
        precondition(after.cpuMaterializations == 1 && after.cpuMaterializationBytes == 256)
        precondition(after.desktopVisibleSubscriptions == 1 && after.displayChannelCount == 1)
        var mutable = frame.pixels
        mutable[0] ^= 0xff
        precondition(frame.pixels == expected && mutable != frame.pixels)
        await session.disconnect()
        subscription.cancel()
        precondition(frame.pixels == expected)
        for index in 0..<2 {
            let codec: SpiceVideoCodecPolicy = index == 0 ? .h264AndMJPEG : .h265AndMJPEG
            _ = try await session.connect(endpoint: SpiceEndpoint(host: "127.0.0.1", port: UInt16(args[3 + index])!, videoCodecPolicy: codec),
                                          credentials: SpiceCredentials(password: "synthetic-test"))
            let reset = await session.diagnosticsSnapshot()
            precondition(reset.cpuMaterializations == 0)
            announce("video \(index)")
            var failed = false
            for await event in session.events {
                guard case let .failed(error) = event else { continue }
                guard case let .videoCodecUnavailable(failure) = error else {
                    preconditionFailure("wrong video failure: \(error)")
                }
                precondition(failure.codec == (index == 0 ? .h264 : .h265))
                guard case let .unsupportedFormat(status) = failure.reason, status < 0 else {
                    preconditionFailure("lost native status")
                }
                failed = true
                break
            }
            precondition(failed)
            await session.disconnect()
        }
        announce("Swift native pixels, mutation isolation, diagnostics and typed video errors passed")
    }
}
