import CSpiceZig
import Foundation

public enum SpiceWebDAVAccessMode: Sendable, Equatable {
    case readOnly
    case readWrite
}

public enum SpiceWebDAVServerError: Error, Sendable, Equatable {
    case invalidRoot
    case invalidRequest
    case headerTooLarge
    case bodyTooLarge
    case tooManyClients
    case pathEscapesRoot
}

// Native server reference ownership pins an immutable filesystem root and a
// synchronized admission queue. Its compatibility calls serialize internally;
// attached executors retain this same server until all native workers join.
final class ZigWebDAVServerOwner: @unchecked Sendable {
    let raw: OpaquePointer
    init(_ raw: OpaquePointer) { self.raw = raw }
    deinit { spice_zig_webdav_server_destroy(raw) }
}

/// An explicit-root WebDAV server. Filesystem writes require readWrite opt-in.
public actor SpiceWebDAVServer {
    public nonisolated let root: URL
    public nonisolated let accessMode: SpiceWebDAVAccessMode
    nonisolated let owner: ZigWebDAVServerOwner

    public init(root: URL, accessMode: SpiceWebDAVAccessMode = .readOnly,
                maximumClients: Int = 64, maximumHeaderBytes: Int = 64 * 1_024,
                maximumBodyBytes: Int = 64 * 1_024 * 1_024) throws(SpiceWebDAVServerError) {
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.isFileURL, maximumClients > 0, maximumHeaderBytes > 0,
              maximumBodyBytes >= 0 else { throw .invalidRoot }
        self.root = resolved
        self.accessMode = accessMode
        var options = SpiceZigWebDAVOptions()
        spice_zig_webdav_options(&options)
        options.read_write = accessMode == .readWrite ? 1 : 0
        options.maximum_clients = maximumClients
        options.maximum_header_bytes = maximumHeaderBytes
        options.maximum_body_bytes = maximumBodyBytes
        let path = Array(resolved.path.utf8)
        var raw: OpaquePointer?
        let status = path.withUnsafeBufferPointer {
            spice_zig_webdav_server_create($0.baseAddress, $0.count, &options, &raw)
        }
        if status == -2 { preconditionFailure("WebDAV server allocation failed") }
        guard status == 0, let raw else { throw .invalidRoot }
        owner = ZigWebDAVServerOwner(raw)
    }

    public func receive(clientID: Int64, data: Data) throws(SpiceWebDAVServerError) -> [Data] {
        try receiveNative(clientID: clientID, data: data)
    }
    private nonisolated func receiveNative(clientID: Int64, data: Data) throws(SpiceWebDAVServerError) -> [Data] {
        var responses: OpaquePointer?
        let status = data.withUnsafeBytes {
            spice_zig_webdav_server_receive(owner.raw, clientID, $0.bindMemory(to: UInt8.self).baseAddress,
                                           $0.count, &responses)
        }
        switch status {
        case 0: break
        case -2: preconditionFailure("WebDAV response allocation failed")
        case -55: throw .headerTooLarge
        case -56: throw .bodyTooLarge
        case -57: throw .tooManyClients
        case -58: throw .pathEscapesRoot
        default: throw .invalidRequest
        }
        guard let responses else { preconditionFailure("WebDAV response ownership missing") }
        defer { spice_zig_webdav_responses_destroy(responses) }
        return (0..<spice_zig_webdav_responses_count(responses)).map { index in
            var size = 0
            let bytes = spice_zig_webdav_responses_bytes(responses, index, &size)
            guard size > 0 else { return Data() }
            precondition(bytes != nil)
            return Data(bytes: bytes!, count: size)
        }
    }
    public func close(clientID: Int64) { spice_zig_webdav_server_close(owner.raw, clientID, 0) }
    public func closeAll() { spice_zig_webdav_server_close(owner.raw, 0, 1) }
}

// Route borrows the runner; the lease removes that borrow and joins work before
// releasing Runtime. The runner owns its own reference to the supplied server.
final class ZigWebDAVLease: @unchecked Sendable {
    let runtime: ZigRuntime
    let raw: OpaquePointer
    init(runtime: ZigRuntime, server: ZigWebDAVServerOwner, channel: UInt8) throws(SpiceError) {
        self.runtime = runtime
        var raw: OpaquePointer?
        let status = spice_zig_webdav_create_shared(runtime.raw, channel, server.raw, &raw)
        guard status == 0, let raw else { throw .protocolError("WebDAV backend creation (\(status))") }
        let attached = spice_zig_webdav_route_attach(runtime.webDAVRoute, runtime.raw, raw)
        guard attached == 0 else {
            spice_zig_webdav_destroy(raw)
            throw .protocolError("WebDAV backend attachment (\(attached))")
        }
        self.raw = raw
    }
    func stop() { spice_zig_webdav_stop(raw) }
    deinit {
        spice_zig_webdav_route_detach(runtime.webDAVRoute, raw)
        spice_zig_webdav_destroy(raw)
    }
}
