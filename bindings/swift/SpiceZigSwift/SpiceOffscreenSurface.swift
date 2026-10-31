import CSpiceZig

/// Viewer-only local drawing; storage, bounds checks and publications live in Zig.
@MainActor
package final class SpiceOffscreenSurface {
    private let raw: OpaquePointer
    package init() {
        var value: OpaquePointer?
        precondition(spice_zig_offscreen_create(&value) == 0, "offscreen allocation failed")
        raw = value!
    }
    isolated deinit { spice_zig_offscreen_destroy(raw) }
    package func create(id: UInt32, width: UInt32, height: UInt32, format: UInt32) throws {
        try check(spice_zig_offscreen_surface(raw, id, width, height, format))
    }
    package func fill(surfaceID: UInt32, rectangle: SpicePixelRect, colorARGB: UInt32) throws {
        guard let x = Int32(exactly: rectangle.x), let y = Int32(exactly: rectangle.y),
              let width = UInt32(exactly: rectangle.width), let height = UInt32(exactly: rectangle.height)
        else { throw SpiceError.protocolError("invalid offline rectangle") }
        var rect = SpiceZigDamageRect(x: x, y: y, width: width, height: height)
        try check(spice_zig_offscreen_fill(raw, surfaceID, &rect, colorARGB))
    }
    package func snapshot(surfaceID: UInt32) throws -> SpiceFrame {
        var frame: OpaquePointer?
        try check(spice_zig_offscreen_frame(raw, surfaceID, &frame))
        return SpiceFrame(taking: frame!)
    }
    private func check(_ result: Int32) throws {
        guard result == 0 else { throw SpiceError.protocolError("offline surface (\(result))") }
    }
}

extension SpiceDesktopSource {
    package convenience init() {
        do { self.init(runtime: try ZigResources.runtime()) }
        catch { preconditionFailure("desktop initialization failed") }
    }
    package func beginSyntheticDesktop() {
        let status = spice_zig_source_begin_synthetic(runtime.source)
        if status != 0 { runtime.fail(.protocolError("offline desktop (\(status))")) }
    }
    package func publishSyntheticFrame(_ frame: SpiceFrame) throws {
        guard let owner = frame.nativeOwner else { throw SpiceError.protocolError("offline frame has no native owner") }
        let status = spice_zig_source_publish_synthetic(runtime.source, owner.raw)
        guard status == 0 else { throw SpiceError.protocolError("offline publication (\(status))") }
    }
}
