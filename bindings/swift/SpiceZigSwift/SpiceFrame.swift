import CSpiceZig
import Foundation
import IOSurface
import Synchronization

// Each owner holds one immutable C frame lease. Native readback is synchronized
// inside Zig, and the final release occurs after every Swift reader releases it.
// OpaquePointer has no Sendable conformance; no mutable Swift state is shared.
final class ZigFrameOwner: @unchecked Sendable {
    let raw: OpaquePointer
    let info: SpiceZigFrameInfo

    init(taking raw: OpaquePointer) {
        self.raw = raw
        var info = SpiceZigFrameInfo()
        precondition(spice_zig_frame_info(raw, &info) == 0)
        self.info = info
    }

    deinit { spice_zig_frame_release(raw) }

    private let materialization = Mutex<Data?>(nil)

    func pixels() -> Data {
        materialization.withLock { cached in
            if let cached { return cached }
            var result = Data(count: Int(info.width) * Int(info.height) * 4)
            let status = result.withUnsafeMutableBytes { bytes in
                spice_zig_frame_copy_pixels(raw, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
            precondition(status == 0, "committed frame could not materialize")
            cached = result
            return result
        }
    }
}

public struct SpiceIOSurfaceFrame: Sendable, Equatable {
    public let id: UInt32
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixelFormat: UInt32
    let owner: ZigFrameOwner

    init?(_ owner: ZigFrameOwner) {
        guard let raw = spice_zig_frame_iosurface(owner.raw) else { return nil }
        let surface = Unmanaged<IOSurfaceRef>.fromOpaque(raw).takeUnretainedValue()
        self.owner = owner
        id = IOSurfaceGetID(surface)
        width = IOSurfaceGetWidth(surface)
        height = IOSurfaceGetHeight(surface)
        bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        pixelFormat = IOSurfaceGetPixelFormat(surface)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.width == rhs.width && lhs.height == rhs.height
            && lhs.bytesPerRow == rhs.bytesPerRow && lhs.pixelFormat == rhs.pixelFormat
    }
}

public struct SpiceFrame: Sendable, Equatable {
    public let surfaceID: UInt32
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let ioSurface: SpiceIOSurfaceFrame?
    let nativeOwner: ZigFrameOwner?
    private let cpuPixels: Data?
    let isAdvancedVideoFrame: Bool

    public var pixels: Data { nativeOwner?.pixels() ?? cpuPixels! }

    init(taking raw: OpaquePointer) {
        let owner = ZigFrameOwner(taking: raw)
        nativeOwner = owner
        cpuPixels = nil
        surfaceID = owner.info.surface_id
        width = Int(owner.info.width)
        height = Int(owner.info.height)
        bytesPerRow = width * 4
        ioSurface = SpiceIOSurfaceFrame(owner)
        isAdvancedVideoFrame = owner.info.advanced_video != 0
    }

    public init(surfaceID: UInt32, width: Int, height: Int, bytesPerRow: Int,
                pixels: consuming Data) {
        self.surfaceID = surfaceID
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        cpuPixels = pixels
        nativeOwner = nil
        ioSurface = nil
        isAdvancedVideoFrame = false
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.surfaceID == rhs.surfaceID, lhs.width == rhs.width,
              lhs.height == rhs.height, lhs.bytesPerRow == rhs.bytesPerRow,
              lhs.isAdvancedVideoFrame == rhs.isAdvancedVideoFrame else { return false }
        if let owner = lhs.nativeOwner, owner === rhs.nativeOwner { return true }
        // SwiftUI equality must never trigger GPU readback.
        guard lhs.ioSurface == nil, rhs.ioSurface == nil else { return false }
        return lhs.pixels == rhs.pixels
    }
}
