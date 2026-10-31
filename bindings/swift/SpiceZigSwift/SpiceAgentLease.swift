import CSpiceZig
import Foundation

struct ZigAgentFailure: Error, Sendable {
    let reason: String
    var actual: UInt64 = 0
    var maximum: UInt64 = 0
}
struct ZigFileKey: Sendable {
    let id: UInt32
    let incarnation: UInt64
    var native: SpiceZigFileKey { SpiceZigFileKey(id: id, reserved: 0, incarnation: incarnation) }
}
// The native route borrows raw until detach joins observers. This lease retains
// Runtime until the runner and its worker have been destroyed, with no back edge.
final class ZigAgentLease: @unchecked Sendable {
    let runtime: ZigRuntime
    let raw: OpaquePointer
    init(runtime: ZigRuntime, options: SpiceZigAgentOptions, interval: UInt32, firstFileID: UInt32) throws {
        self.runtime = runtime
        var runner: OpaquePointer?
        var options = options
        let result = spice_zig_agent_runner_create_seeded(runtime.raw, &options, nil, 0, 1, interval, firstFileID, &runner)
        guard result == 0, let runner else { throw ZigAgentFailure(reason: "agent initialization (\(result))") }
        let attached = spice_zig_agent_route_attach(runtime.agentRoute, runner)
        guard attached == 0 else {
            spice_zig_agent_runner_destroy(runner)
            throw ZigAgentFailure(reason: attached == -53 ? "AgentAlreadyAttached" : "agent attachment (\(attached))")
        }
        raw = runner
    }
    func publish(_ text: String) async -> Int32 {
        // The dispatch closure retains this lease and caller text through the
        // blocking native borrow. Stop cancels/join-wakes all queued borrowers.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let status = text.utf8CString.withUnsafeBytes { bytes in
                    spice_zig_agent_runner_publish_borrowed(raw, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count - 1)
                }
                continuation.resume(returning: status)
            }
        }
    }
    func join() {
        spice_zig_agent_route_detach(runtime.agentRoute, raw)
        spice_zig_agent_runner_join(raw)
    }
    deinit {
        spice_zig_agent_route_detach(runtime.agentRoute, raw)
        spice_zig_agent_runner_destroy(raw)
    }
}
