import CSpiceZig
import Dispatch
import Foundation
import Synchronization

// Owns the stable Desktop and its Source adapter. C operations document their
// synchronization; Session serializes connect/reset/join. Every dispatched call
// retains this owner, so neither pointer can be destroyed under an active call.
final class ZigRuntime: @unchecked Sendable {
    let raw: OpaquePointer
    let source: OpaquePointer
    let audioRoute: OpaquePointer
    let agentRoute: OpaquePointer
    let webDAVRoute: OpaquePointer
    let usbRoute: OpaquePointer
    let diagnostics: ZigDiagnosticsOwner
    let initializationFallback: Bool
    let receiveQueue = DispatchQueue(label: "SwiftSpice.session.receiver", qos: .userInteractive)
    let sendQueue = DispatchQueue(label: "SwiftSpice.session.sender", qos: .userInteractive)
    private let boundaryFailure = Mutex<SpiceError?>(nil)

    init(compositor: String? = nil, initializationFallback: Bool = false) throws {
        self.initializationFallback = initializationFallback
        var desktop: OpaquePointer?
        let result: Int32
        if let compositor {
            result = compositor.withCString { spice_zig_desktop_create($0, 0, &desktop) }
        } else {
            result = spice_zig_desktop_create(nil, 0, &desktop)
        }
        guard result == 0, let desktop else {
            throw SpiceError.connectionFailed("desktop initialization (\(result))")
        }
        raw = desktop
        var options = SpiceZigSourceOptions()
        spice_zig_source_options(&options)
        var source: OpaquePointer?
        let sourceResult = spice_zig_source_create(desktop, &options, &source)
        guard sourceResult == 0, let source else {
            spice_zig_desktop_destroy(desktop)
            throw SpiceError.connectionFailed("desktop source initialization (\(sourceResult))")
        }
        self.source = source
        var route: OpaquePointer?
        guard spice_zig_audio_route_create(&route) == 0, let route else {
            spice_zig_source_destroy(source)
            spice_zig_desktop_destroy(desktop)
            throw SpiceError.connectionFailed("audio route initialization")
        }
        audioRoute = route
        var agentRoute: OpaquePointer?
        guard spice_zig_agent_route_create(&agentRoute) == 0, let agentRoute else {
            spice_zig_audio_route_destroy(route)
            spice_zig_source_destroy(source)
            spice_zig_desktop_destroy(desktop)
            throw SpiceError.connectionFailed("agent route initialization")
        }
        self.agentRoute = agentRoute
        var usbRoute: OpaquePointer?
        guard spice_zig_usb_route_create(&usbRoute) == 0, let usbRoute else {
            spice_zig_agent_route_destroy(agentRoute)
            spice_zig_audio_route_destroy(route)
            spice_zig_source_destroy(source)
            spice_zig_desktop_destroy(desktop)
            throw SpiceError.connectionFailed("USB route initialization")
        }
        self.usbRoute = usbRoute
        var webDAVRoute: OpaquePointer?
        guard spice_zig_webdav_route_create(&webDAVRoute) == 0, let webDAVRoute else {
            spice_zig_usb_route_destroy(usbRoute)
            spice_zig_agent_route_destroy(agentRoute)
            spice_zig_audio_route_destroy(route)
            spice_zig_source_destroy(source)
            spice_zig_desktop_destroy(desktop)
            throw SpiceError.connectionFailed("WebDAV route initialization")
        }
        self.webDAVRoute = webDAVRoute
        do { diagnostics = try ZigDiagnosticsOwner(source: source) }
        catch {
            spice_zig_webdav_route_destroy(webDAVRoute)
            spice_zig_usb_route_destroy(usbRoute)
            spice_zig_agent_route_destroy(agentRoute)
            spice_zig_audio_route_destroy(route)
            spice_zig_source_destroy(source)
            spice_zig_desktop_destroy(desktop)
            throw error
        }
    }

    func fail(_ error: SpiceError) {
        boundaryFailure.withLock { if $0 == nil { $0 = error } }
        spice_zig_desktop_cancel(raw)
    }

    var failure: SpiceError? { boundaryFailure.withLock { $0 } }
    func clearFailure() { boundaryFailure.withLock { $0 = nil } }

    deinit {
        spice_zig_desktop_cancel(raw)
        spice_zig_desktop_join(raw)
        spice_zig_webdav_route_destroy(webDAVRoute)
        spice_zig_usb_route_destroy(usbRoute)
        spice_zig_agent_route_destroy(agentRoute)
        spice_zig_audio_route_destroy(audioRoute)
        spice_zig_source_destroy(source)
        spice_zig_desktop_destroy(raw)
    }
}

public final class SpiceDesktopSource: Sendable {
    let runtime: ZigRuntime
    init(runtime: ZigRuntime) { self.runtime = runtime }

    public func subscribe(surface: SpiceSurfaceSelection = .primary) -> SpiceDesktopSubscription {
        let selection = surface.nativeSelection
        var raw: OpaquePointer?
        let status = spice_zig_source_subscribe(runtime.source, selection.channel, selection.surface, &raw)
        guard status == 0, let raw else {
            runtime.fail(.protocolError("desktop subscription (\(status))"))
            return SpiceDesktopSubscription(owner: nil)
        }
        return SpiceDesktopSubscription(owner: ZigSubscriptionOwner(raw: raw, runtime: runtime))
    }
}

// One serial blocking consumer per native subscription. It does not buffer
// frames: Zig owns the bounded pending snapshot, damage merge and consumption ACK.
// Cancellation wakes C next; the queued closure retains the handle until return.
// The native Source bounds the number of subscriptions (and hence waiting queues).
private final class ZigSubscriptionOwner: @unchecked Sendable {
    let raw: OpaquePointer
    let runtime: ZigRuntime
    let queue = DispatchQueue(label: "SwiftSpice.desktop.subscription", qos: .userInteractive)
    init(raw: OpaquePointer, runtime: ZigRuntime) { self.raw = raw; self.runtime = runtime }
    func cancel() { spice_zig_subscription_cancel(raw) }
    deinit { spice_zig_subscription_destroy(raw) }

    func next() async -> SpiceDesktopSnapshot? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    var snapshot: OpaquePointer?
                    let status = spice_zig_subscription_next(raw, 1, &snapshot)
                    guard status == 1, let snapshot else {
                        if status < 0 {
                            runtime.fail(.protocolError("desktop update (\(status))"))
                            cancel()
                        }
                        continuation.resume(returning: nil)
                        return
                    }
                    defer { spice_zig_snapshot_destroy(snapshot) }
                    continuation.resume(returning: SpiceDesktopSnapshot(native: snapshot))
                }
            }
        } onCancel: { self.cancel() }
    }
}

public final class SpiceDesktopSubscription: Sendable {
    public let updates: AsyncStream<SpiceDesktopSnapshot>
    private let owner: ZigSubscriptionOwner?

    fileprivate init(owner: ZigSubscriptionOwner?) {
        self.owner = owner
        updates = AsyncStream(unfolding: { await owner?.next() })
    }

    public func setDemand(_ demand: SpiceDesktopDemand) {
        guard let owner else { return }
        let status = spice_zig_subscription_demand(owner.raw, demand == .visible ? 1 : 0)
        if status < 0 { owner.runtime.fail(.protocolError("desktop demand (\(status))")) }
    }
    public func cancel() { owner?.cancel() }
    deinit { cancel() }
}

extension SpiceDesktopSnapshot {
    init(native: OpaquePointer) {
        var info = SpiceZigSnapshotInfo()
        precondition(spice_zig_snapshot_info(native, &info) == 0)
        var nativeFrame: OpaquePointer?
        let status = spice_zig_snapshot_frame(native, &nativeFrame)
        precondition(status >= 0, "desktop frame could not be retained")
        let update: SpiceFrameUpdate?
        if let nativeFrame {
            let frame = SpiceFrame(taking: nativeFrame)
            let metadata = frame.nativeOwner!.info
            var rectangles: [SpicePixelRect] = []
            for index in 0..<Int(metadata.damage_count) {
                var rect = SpiceZigDamageRect()
                precondition(spice_zig_frame_damage(nativeFrame, index, &rect) == 0)
                rectangles.append(SpicePixelRect(x: Int(rect.x), y: Int(rect.y),
                                                 width: Int(rect.width), height: Int(rect.height)))
            }
            let full = [SpicePixelRect(x: 0, y: 0, width: frame.width, height: frame.height)]
            update = SpiceFrameUpdate(frame: frame,
                revision: SpiceFrameRevision(surface: SpiceSurfaceIdentity(
                    displayChannelID: info.channel_id, surfaceID: metadata.surface_id,
                    generation: metadata.lifecycle), value: metadata.revision),
                damage: rectangles == full ? .full : .rectangles(rectangles),
                deliverySequence: info.frame_sequence)
        } else { update = nil }
        var cursor = SpiceZigSnapshotCursor()
        var bytes: UnsafePointer<UInt8>?
        var count = 0
        let cursorStatus = spice_zig_snapshot_cursor(native, &cursor, &bytes, &count)
        precondition(cursorStatus >= 0)
        let state: SpiceCursorState?
        if cursorStatus == 1 {
            let image: SpiceCursorImage?
            if cursor.has_image != 0,
               let format = UInt8(exactly: cursor.format).flatMap(SpiceCursorImageFormat.init(rawValue:)) {
                image = SpiceCursorImage(id: cursor.unique, format: format,
                    width: Int(cursor.width), height: Int(cursor.height),
                    hotSpotX: Int(cursor.hot_x), hotSpotY: Int(cursor.hot_y),
                    data: count == 0 ? Data() : Data(bytes: bytes!, count: count))
            } else { image = nil }
            state = SpiceCursorState(x: Int(cursor.x), y: Int(cursor.y),
                                     isVisible: cursor.visible != 0, image: image)
        } else { state = nil }
        self.init(generation: info.generation, frame: update, cursor: state,
                  pointerMode: info.pointer_mode == 0 ? .absolute : .relative,
                  deliverySequence: info.delivery_sequence)
    }
}
