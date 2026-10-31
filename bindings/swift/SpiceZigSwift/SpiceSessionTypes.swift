import Foundation
import Synchronization

public struct SpiceEndpoint: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var tlsPolicy: TLSTrustPolicy?
    public var videoCodecPolicy: SpiceVideoCodecPolicy

    public init(
        host: String,
        port: UInt16,
        tlsPolicy: TLSTrustPolicy? = nil,
        videoCodecPolicy: SpiceVideoCodecPolicy = .mjpegOnly
    ) {
        self.host = host
        self.port = port
        self.tlsPolicy = tlsPolicy
        self.videoCodecPolicy = videoCodecPolicy
    }
}

/// Controls codecs advertised to the SPICE Display peer. H.264 is opt-in
/// because some host encoders emit 4:4:4 profiles unsupported by VideoToolbox.
public enum SpiceVideoCodecPolicy: Sendable, Equatable {
    case mjpegOnly
    case h264AndMJPEG
    case h265AndMJPEG
}

public enum SpiceVideoCodec: Sendable, Equatable {
    case h264
    case h265
}

public enum SpiceVideoCodecFailureReason: Sendable, Equatable {
    case hardwareUnavailable(status: Int32?)
    case unsupportedFormat(status: Int32)
}

public struct SpiceVideoCodecFailure: Sendable, Equatable {
    public let codec: SpiceVideoCodec
    public let reason: SpiceVideoCodecFailureReason

    public init(codec: SpiceVideoCodec, reason: SpiceVideoCodecFailureReason) {
        self.codec = codec
        self.reason = reason
    }
}

public enum TLSTrustPolicy: Sendable, Equatable {
    case system
    /// Trust only the supplied CA certificates. Values may be DER or PEM data;
    /// escaped PEM from a virt-viewer `ca=` field is accepted directly.
    /// `serverName` overrides hostname verification when the connection address
    /// differs from the name in the server certificate.
    case customCertificateAuthority(certificates: [Data], serverName: String? = nil)
    /// Trust only the supplied CA certificates and require the complete leaf
    /// subject to match a virt-viewer `host-subject` value. Use this explicit
    /// compatibility policy for legacy SPICE certificates without SAN or a
    /// Server Authentication EKU; modern hostname validation remains available
    /// through `customCertificateAuthority`.
    case virtViewerCertificateAuthority(certificates: [Data], expectedSubject: String)
    case insecureForTestingOnly
}

public struct SpiceCredentials: ~Copyable, Sendable {
    private let storage: SpiceCredentialStorage

    public init(password: String = "") {
        storage = SpiceCredentialStorage(password: Data(password.utf8))
    }

    consuming package func transferStorage() -> SpiceCredentialStorage {
        storage
    }
}

package final class SpiceCredentialStorage: Sendable {
    private let passwordBytes: Mutex<Data>

    fileprivate init(password: consuming Data) {
        passwordBytes = Mutex(password)
    }

    package func copyPassword() -> Data {
        passwordBytes.withLock { value in
            var copy = Data(capacity: value.count)
            copy.append(contentsOf: value)
            return copy
        }
    }

    deinit {
        passwordBytes.withLock { value in
            value.resetBytes(in: value.indices)
        }
    }
}

public struct SpiceChannelDescriptor: Sendable, Hashable {
    public let type: UInt8
    public let id: UInt8
}

public struct SpiceSessionInfo: Sendable, Equatable {
    public let sessionID: UInt32
    public let supportedMouseModes: UInt32
    public let currentMouseMode: UInt32
    public let agentConnected: Bool
    public let channels: [SpiceChannelDescriptor]
}

public enum SpiceError: Error, Sendable, Equatable, CustomStringConvertible {
    case alreadyConnected
    case connectionFailed(String)
    case authenticationFailed(String)
    case protocolError(String)
    case videoCodecUnavailable(SpiceVideoCodecFailure)
    case cancelled

    public var description: String {
        switch self {
        case .alreadyConnected:
            "session is already connected"
        case let .connectionFailed(reason):
            "connection failed: \(reason)"
        case let .authenticationFailed(reason):
            "authentication failed: \(reason)"
        case let .protocolError(reason):
            "protocol error: \(reason)"
        case let .videoCodecUnavailable(failure):
            "video codec unavailable: \(failure.codec) (\(failure.reason))"
        case .cancelled:
            "connection cancelled"
        }
    }
}

