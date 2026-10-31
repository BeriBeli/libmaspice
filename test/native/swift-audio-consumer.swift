import Foundation
import SwiftSpice

func announce(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }
@main struct Consumer {
    static func main() async throws {
        let ports = CommandLine.arguments.dropFirst().map { UInt16($0)! }
        let session = SpiceSession()
        let sink = SpiceAudioPlaybackSink()
        let capture = SpiceAudioCaptureSource()
        var played = sink.events.makeAsyncIterator()
        var recorded = capture.events.makeAsyncIterator()
        for run in 0..<2 {
            _ = try await session.connect(endpoint: .init(host: "127.0.0.1", port: ports[run]), credentials: .init(password: "synthetic-test"))
            announce("ready \(run)")
            if run == 0 {
                // Establish that the event was received before service start,
                // using the public stream rather than a scheduling delay.
                var incoming = session.recordEvents.makeAsyncIterator()
                let received = await incoming.next()
                precondition(received == .muteChanged(true))
                try await sink.start(session: session)
                try await capture.start(session: session)
                do { try await capture.start(session: session); preconditionFailure("duplicate start") }
                catch SpiceAudioCaptureSourceError.alreadyRunning { }
            }
            for index in 0..<40 {
                let expected = index % 2 == 0
                var play: SpiceAudioPlaybackSinkEvent?
                repeat { play = await played.next() } while play == .stopped
                precondition(play == .muteChanged(expected))
                var record: SpiceAudioCaptureSourceEvent?
                repeat { record = await recorded.next() } while record == .stopped
                precondition(record == .muteChanged(expected))
                announce("received \(run) \(index)")
            }
            await session.disconnect()
        }
        await sink.stop(); await capture.stop()
        let stats = await sink.statistics()
        precondition(stats.scheduledPackets == 0 && stats.scheduledFrames == 0)
        // Native teardown is joined; a fresh facade can acquire the same route.
        let replacement = SpiceAudioPlaybackSink()
        try await replacement.start(session: session)
        await replacement.stop()
        announce("Swift audio late attachment, stream draining, reconnect and joined stop passed")
    }
}
