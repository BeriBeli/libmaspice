import Foundation

private final class ZigResourceBundleFinder {}

enum ZigResources {
    static func library(_ name: String) -> String? {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: name, withExtension: "metallib") { return url.path() }
        #endif
        for bundle in [Bundle.main, Bundle(for: ZigResourceBundleFinder.self)] {
            var roots = [bundle.bundleURL]
            if let url = bundle.resourceURL { roots.append(url) }
            if let url = bundle.executableURL { roots.append(url.deletingLastPathComponent()) }
            if bundle.bundleURL.pathExtension == "xctest" {
                roots.append(bundle.bundleURL.deletingLastPathComponent())
            }
            for root in roots {
                guard let resources = Bundle(url: root.appending(path: "SwiftSpice_SwiftSpice.bundle")),
                      let library = resources.url(forResource: name, withExtension: "metallib") else { continue }
                return library.path()
            }
        }
        return nil
    }

    static func runtime() throws -> ZigRuntime {
        if let compositor = library("SpiceZigCompositor"),
           let runtime = try? ZigRuntime(compositor: compositor) { return runtime }
        // Surface composition has always supported a CPU fallback. Packaging
        // validation separately requires both shader resources to be present.
        return try ZigRuntime(initializationFallback: true)
    }
}
