import AppKit
import SwiftSpice
import SwiftUI

@MainActor func nativeView(_ view: NSView) -> NSView? {
    if NSStringFromClass(type(of: view)) == "SZHostView" { return view }
    for child in view.subviews { if let result = nativeView(child) { return result } }
    return nil
}
@MainActor func layout(_ view: NSView) {
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002))
}
@MainActor final class Inputs {
    var first: [SpiceClientInput] = []
    var second: [SpiceClientInput] = []
}
@main struct Consumer {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let first = SpiceSession(), second = SpiceSession(), inputs = Inputs()
        let hosting = NSHostingView(rootView: AnyView(SpiceDesktopView(desktop: first.desktop) { inputs.first.append($0) }))
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        for _ in 0..<100 {
            layout(hosting)
            if await first.diagnosticsSnapshot().desktopSubscriptions == 1 { break }
            await Task.yield()
        }
        let attached = await first.diagnosticsSnapshot()
        precondition(attached.desktopSubscriptions == 1)
        let view = nativeView(hosting)!
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        view.keyDown(with: down)
        precondition(inputs.first == [.keyDown(scanCode: 0x1e)])
        hosting.rootView = AnyView(SpiceDesktopView(desktop: first.desktop) { inputs.second.append($0) })
        layout(hosting)
        let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        nativeView(hosting)!.keyUp(with: up)
        precondition(inputs.first.count == 1 && inputs.second == [.keyUp(scanCode: 0x1e)])
        hosting.rootView = AnyView(SpiceDesktopView(desktop: second.desktop, surface: .surface(displayChannelID: 2, surfaceID: 7)) { _ in })
        for _ in 0..<100 {
            layout(hosting)
            if await second.diagnosticsSnapshot().desktopSubscriptions == 1 { break }
            await Task.yield()
        }
        let removed = await first.diagnosticsSnapshot(), replaced = await second.diagnosticsSnapshot()
        precondition(removed.desktopSubscriptions == 0 && replaced.desktopSubscriptions == 1)
        hosting.rootView = AnyView(EmptyView())
        for _ in 0..<100 {
            layout(hosting)
            if await second.diagnosticsSnapshot().desktopSubscriptions == 0 { break }
            await Task.yield()
        }
        let dismantled = await second.diagnosticsSnapshot()
        precondition(dismantled.desktopSubscriptions == 0)
        print("SwiftUI native view subscription replacement, callback update and dismantle passed")
    }
}
