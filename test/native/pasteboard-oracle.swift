import AppKit
// Error-type-only build shim. The original pasteboard implementation is compiled
// unchanged; it references only this case and no protocol/session dependencies.
public enum SpiceClipboardError: Error { case pasteboardWriteFailed }
@_cdecl("pasteboard_swift_roundtrip")
@MainActor public func roundtrip(_ input: UnsafePointer<UInt8>, _ count: Int,
                                _ output: UnsafeMutablePointer<UInt8>, _ capacity: Int) -> Int {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    do {
        let text = String(decoding: UnsafeBufferPointer(start: input, count: count), as: UTF8.self)
        let snapshot = try SpicePasteboardBridge.write(text: text, to: board)
        guard let bytes = snapshot.text.map({ Array($0.utf8) }), bytes.count <= capacity else { return -1 }
        output.update(from: bytes, count: bytes.count)
        return bytes.count
    } catch { return -1 }
}
