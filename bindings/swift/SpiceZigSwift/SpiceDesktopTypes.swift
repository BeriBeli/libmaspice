import Foundation

public struct SpiceSurfaceIdentity: Sendable, Hashable {
    public let displayChannelID: UInt8
    public let surfaceID: UInt32
    public let generation: UInt64

    public init(displayChannelID: UInt8, surfaceID: UInt32, generation: UInt64) {
        self.displayChannelID = displayChannelID
        self.surfaceID = surfaceID
        self.generation = generation
    }
}

public struct SpicePixelRect: Sendable, Hashable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct SpiceFrameRevision: Sendable, Hashable {
    public let surface: SpiceSurfaceIdentity
    public let value: UInt64

    public init(surface: SpiceSurfaceIdentity, value: UInt64) {
        self.surface = surface
        self.value = value
    }
}

public enum SpiceDamageRegion: Sendable, Equatable {
    case full
    case rectangles([SpicePixelRect])
}

public struct SpiceFrameUpdate: Sendable {
    public let frame: SpiceFrame
    public let revision: SpiceFrameRevision
    public let damage: SpiceDamageRegion
    package let deliverySequence: UInt64

    public init(
        frame: SpiceFrame,
        revision: SpiceFrameRevision,
        damage: SpiceDamageRegion
    ) {
        self.frame = frame
        self.revision = revision
        self.damage = damage
        deliverySequence = 0
    }

    package init(
        frame: SpiceFrame,
        revision: SpiceFrameRevision,
        damage: SpiceDamageRegion,
        deliverySequence: UInt64
    ) {
        self.frame = frame
        self.revision = revision
        self.damage = damage
        self.deliverySequence = deliverySequence
    }
}

public struct SpiceDesktopSnapshot: Sendable {
    public let generation: UInt64
    public let frame: SpiceFrameUpdate?
    public let cursor: SpiceCursorState?
    public let pointerMode: SpicePointerMode
    package let deliverySequence: UInt64
    package var frameDeliverySequence: UInt64? { frame?.deliverySequence }

    public init(
        generation: UInt64,
        frame: SpiceFrameUpdate?,
        cursor: SpiceCursorState?,
        pointerMode: SpicePointerMode
    ) {
        self.generation = generation
        self.frame = frame
        self.cursor = cursor
        self.pointerMode = pointerMode
        deliverySequence = 0
    }

    package init(
        generation: UInt64,
        frame: SpiceFrameUpdate?,
        cursor: SpiceCursorState?,
        pointerMode: SpicePointerMode,
        deliverySequence: UInt64
    ) {
        self.generation = generation
        self.frame = frame.map {
            guard $0.deliverySequence == 0, deliverySequence != 0 else { return $0 }
            return SpiceFrameUpdate(
                frame: $0.frame,
                revision: $0.revision,
                damage: $0.damage,
                deliverySequence: deliverySequence
            )
        }
        self.cursor = cursor
        self.pointerMode = pointerMode
        self.deliverySequence = deliverySequence
    }
}

public enum SpiceSurfaceSelection: Sendable, Hashable {
    case primary
    case surface(displayChannelID: UInt8, surfaceID: UInt32)

    var nativeSelection: (channel: UInt8, surface: UInt32) {
        switch self {
        case .primary: (0, 0)
        case let .surface(channel, surface): (channel, surface)
        }
    }

}

public enum SpiceDesktopDemand: Sendable, Hashable {
    case none
    case visible
}

public enum SpicePointerMode: Sendable, Equatable {
    case relative
    case absolute

    public init(spiceMouseMode: UInt32) {
        self = spiceMouseMode == 2 ? .absolute : .relative
    }
}

