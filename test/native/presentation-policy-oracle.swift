// Compiled with exact extracted existing Swift value-policy definitions.
import Foundation
@main struct Oracle {
    static func main() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let commands = try JSONDecoder().decode([[Int]].self, from: input)
        func revision(_ value: Int) -> SpiceFrameRevision {
            SpiceFrameRevision(surface: .init(displayChannelID: UInt8(value % 3), surfaceID: UInt32(value % 5), generation: UInt64(value / 10)), value: UInt64(value))
        }
        var pacing = SpiceDesktopPresentationPacingPolicy()
        var metal = SpiceMetalFailureRecoveryPolicy()
        var drop = SpiceDrawablePresentationDropRecoveryPolicy()
        var attempts: [SpiceMetalFailureRecoveryPolicy.Attempt] = []
        var output: [Int] = []
        for c in commands {
            let result: Int
            switch c[0] {
            case 0:
                switch pacing.readyBecameAvailable() { case .selectImmediately: result = 1; case .waitForDisplayLink: result = 2; default: fatalError() }
            case 1:
                switch pacing.displayLinkFired(hasReadySnapshot: c[1] != 0) { case .selectOnDisplayLink: result = 3; case .pauseDisplayLink: result = 4; default: fatalError() }
            case 2: pacing.reset(); result = 0
            case 10: attempts.append(metal.beginAttempt(for: revision(c[1]))); result = attempts.count - 1
            case 11:
                let action = metal.commandCompleted(attempts[c[1]], completion: c[3] == 0 ? .failed : .succeeded, selectedRevision: c[2] < 0 ? nil : revision(c[2]))
                switch action { case .none: result = 0; case .requestLatest: result = 1; case .useCPUFallback: result = 2 }
            case 12: metal.cancelAttempt(attempts[c[1]]); result = 0
            case 13: metal.reset(); result = 0
            case 20: drop.revisionSelected(revision(c[1])); result = 0
            case 21:
                switch drop.presentationDropped(revision: revision(c[1]), selectedRevision: c[2] < 0 ? nil : revision(c[2]), isVisibleDemand: c[3] != 0) { case .none: result = 0; case .requestAuthoritativeRedraw: result = 1 }
            case 22: drop.presentationSucceeded(revision: revision(c[1])); result = 0
            case 23: drop.reset(); result = 0
            default: fatalError()
            }
            output.append(result)
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(output))
    }
}
