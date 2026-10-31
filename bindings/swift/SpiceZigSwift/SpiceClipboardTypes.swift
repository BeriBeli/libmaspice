import Foundation

public enum SpiceClipboardError: Error, Sendable, Equatable, CustomStringConvertible {
    case alreadyRunning
    case invalidAgentMessage(String)
    case invalidUTF8
    case pasteboardWriteFailed
    case transport(SpiceError)

    public var description: String {
        switch self {
        case .alreadyRunning:
            "clipboard synchronization is already running"
        case let .invalidAgentMessage(reason):
            "invalid clipboard agent message: \(reason)"
        case .invalidUTF8:
            "guest clipboard is not valid UTF-8"
        case .pasteboardWriteFailed:
            "macOS pasteboard rejected the UTF-8 text"
        case let .transport(error):
            "clipboard transport failed: \(error)"
        }
    }
}

/// Content-free classification of a clipboard synchronization failure.
///
/// Categories intentionally omit clipboard contents, byte counts, protocol
/// payloads, endpoint details, and underlying error strings.
public enum SpiceClipboardFailureCategory: String, Sendable, Equatable {
    case agentDisconnected = "agent_disconnected"
    case clipboardNotReady = "clipboard_not_ready"
    case unsolicitedData = "unsolicited_data"
    case unexpectedType = "unexpected_type"
    case oversizedGuestText = "oversized_guest_text"
    case invalidUTF8 = "invalid_utf8"
    case decodeFailure = "decode_failure"
    case encodeFailure = "encode_failure"
    case pasteboardWrite = "pasteboard_write"
    case transport
    case other
}

public enum SpiceClipboardEvent: Sendable, Equatable {
    case ready
    case unavailable
    case guestText(String)
    case localTextOffered(byteCount: Int)
    case oversizedLocalText(byteCount: Int, maximum: Int)
    case failed(SpiceClipboardError)
}

