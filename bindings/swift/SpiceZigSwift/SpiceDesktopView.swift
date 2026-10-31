import AppKit
import CSpiceZig
import SwiftUI

/// SwiftUI owns the selected desktop and callback. Zig owns frame selection,
/// damage, cursor, input policy and presentation inside the returned native view.
public struct SpiceDesktopView: NSViewRepresentable {
    public var desktop: SpiceDesktopSource
    public var surface: SpiceSurfaceSelection
    public var onInput: @MainActor @Sendable (SpiceClientInput) -> Void

    public init(desktop: SpiceDesktopSource, surface: SpiceSurfaceSelection = .primary,
                onInput: @escaping @MainActor @Sendable (SpiceClientInput) -> Void) {
        self.desktop = desktop
        self.surface = surface
        self.onInput = onInput
    }
    public func makeNSView(context: Context) -> NSView {
        let view = ZigDesktopContainer(frame: .zero)
        view.update(desktop: desktop, surface: surface, onInput: onInput)
        return view
    }
    public func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ZigDesktopContainer)?.update(desktop: desktop, surface: surface, onInput: onInput)
    }
    public static func dismantleNSView(_ nsView: NSView, coordinator: Void) {
        (nsView as? ZigDesktopContainer)?.close()
    }
}

@MainActor private final class ZigInputBox {
    var onInput: @MainActor @Sendable (SpiceClientInput) -> Void
    init(_ onInput: @escaping @MainActor @Sendable (SpiceClientInput) -> Void) { self.onInput = onInput }
}

@MainActor private final class ZigDesktopContainer: NSView {
    private var desktop: SpiceDesktopSource?
    private var surface: SpiceSurfaceSelection?
    private var nativeView: NSView?
    private var input: ZigInputBox?

    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    required init?(coder: NSCoder) { return nil }

    func update(desktop: SpiceDesktopSource, surface: SpiceSurfaceSelection,
                onInput: @escaping @MainActor @Sendable (SpiceClientInput) -> Void) {
        if self.desktop === desktop, self.surface == surface, let input {
            input.onInput = onInput
            return
        }
        close() // Held-key releases go to the previous desktop's callback.
        self.desktop = desktop
        self.surface = surface
        let input = ZigInputBox(onInput)
        self.input = input
        var callbacks = SpiceZigHostInput(
            context: Unmanaged.passUnretained(input).toOpaque(),
            retain: { if let context = $0 { _ = Unmanaged<ZigInputBox>.fromOpaque(context).retain() } },
            release: { if let context = $0 { Unmanaged<ZigInputBox>.fromOpaque(context).release() } },
            input: { context, kind, x, y, display in
                guard let context, let event = SpiceClientInput(kind: kind, x: x, y: y, display: display) else { return }
                // Native host documents main-thread input callbacks. Retain and
                // release callbacks may run on any thread and access no UI state.
                MainActor.assumeIsolated {
                    Unmanaged<ZigInputBox>.fromOpaque(context).takeUnretainedValue().onInput(event)
                }
            })
        let selection = surface.nativeSelection
        let raw = withOptionalCString(ZigResources.library("SpiceZigPresentation")) {
            spice_zig_host_view_create(desktop.runtime.source, selection.channel, selection.surface, $0, &callbacks)
        }
        guard let raw else {
            desktop.runtime.fail(.protocolError("native desktop view initialization failed"))
            return
        }
        // Transfer the C +1 into ARC. The child closes itself on deallocation;
        // explicit dismantle below stops demand and input before removing it.
        let child = Unmanaged<NSView>.fromOpaque(raw).takeRetainedValue()
        nativeView = child
        child.frame = bounds
        child.autoresizingMask = [.width, .height]
        addSubview(child)
    }

    func close() {
        if let nativeView {
            spice_zig_host_view_close(Unmanaged.passUnretained(nativeView).toOpaque())
            nativeView.removeFromSuperview()
        }
        nativeView = nil
        input = nil
        desktop = nil
        surface = nil
    }
}

extension SpiceClientInput {
    init?(kind: UInt8, x: Int32, y: Int32, display: UInt8) {
        switch kind {
        case 0: self = .keyDown(scanCode: UInt32(bitPattern: x))
        case 1: self = .keyUp(scanCode: UInt32(bitPattern: x))
        case 2: self = .lockModifiers(UInt16(truncatingIfNeeded: x))
        case 3: self = .mouseMotion(dx: x, dy: y)
        case 4: self = .mousePosition(x: UInt32(bitPattern: x), y: UInt32(bitPattern: y), displayID: display)
        case 5, 6:
            guard let byte = UInt8(exactly: x), let button = SpiceMouseButton(rawValue: byte) else { return nil }
            self = kind == 5 ? .mousePress(button) : .mouseRelease(button)
        default: return nil
        }
    }
}
