import Foundation
import Testing
@testable import SwiftSpice

@MainActor
@Test func offlineSurfaceUsesNativePublicationAndRetainsPixels() async throws {
    let source = SpiceDesktopSource()
    source.beginSyntheticDesktop()
    let subscription = source.subscribe()
    defer { subscription.cancel() }
    subscription.setDemand(.visible)
    let store = SpiceOffscreenSurface()
    try store.create(id: 0, width: 640, height: 360, format: 32)
    try store.fill(surfaceID: 0, rectangle: .init(x: 0, y: 0, width: 640, height: 360), colorARGB: 0x00101520)
    try store.fill(surfaceID: 0, rectangle: .init(x: 7, y: 130, width: 96, height: 96), colorARGB: 0x000553a7)
    let first = try store.snapshot(surfaceID: 0)
    #expect(first.nativeOwner != nil)
    #expect(first.pixels.count == 640 * 360 * 4)
    #expect(Array(first.pixels[0..<4]) == [0x20, 0x15, 0x10, 0xff])
    let offset = (130 * 640 + 7) * 4
    #expect(Array(first.pixels[offset..<(offset+4)]) == [0xa7, 0x53, 0x05, 0xff])
    try source.publishSyntheticFrame(first)
    var iterator = subscription.updates.makeAsyncIterator()
    let update = await iterator.next()
    #expect(update?.frame?.frame.pixels == first.pixels)
    var mutable = first.pixels
    mutable[0] = 0
    #expect(first.pixels[0] == 0x20)
    try store.fill(surfaceID: 0, rectangle: .init(x: 0, y: 0, width: 640, height: 360), colorARGB: 0x00abcdef)
    let second = try store.snapshot(surfaceID: 0)
    #expect(Array(second.pixels[0..<4]) == [0xef, 0xcd, 0xab, 0xff])
    #expect(first.pixels[0] == 0x20)
    #expect(ZigResources.library("SpiceZigCompositor") != nil)
    #expect(ZigResources.library("SpiceZigPresentation") != nil)
}

@MainActor
@Test func offlineSurfaceRejectsInvalidDrawingWithoutChangingPublishedPixels() throws {
    let store = SpiceOffscreenSurface()
    try store.create(id: 0, width: 2, height: 2, format: 32)
    let before = try store.snapshot(surfaceID: 0)
    #expect(throws: SpiceError.self) {
        try store.fill(surfaceID: 0, rectangle: .init(x: 1, y: 0, width: 2, height: 1), colorARGB: 0xffffffff)
    }
    #expect(try store.snapshot(surfaceID: 0).pixels == before.pixels)
}
