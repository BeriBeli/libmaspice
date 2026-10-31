import Foundation
import PackagePlugin

@main
struct CompileMetalShaders: BuildToolPlugin {
    func createBuildCommands(
        context: PluginContext,
        target: Target
    ) async throws -> [Command] {
        guard target is SwiftSourceModuleTarget else {
            throw PluginError.unsupportedTarget(target.name)
        }

        let nativeBoundary = target.directoryURL.lastPathComponent == "SpiceZigSwift"
        let sources: [(URL, String)] = nativeBoundary ? [
            (context.package.directoryURL.appending(path: "resources/shaders/compositor.metal"), "SpiceZigCompositor"),
            (context.package.directoryURL.appending(path: "resources/shaders/presentation.metal"), "SpiceZigPresentation"),
        ] : [(target.directoryURL.appending(path: "Shaders/SpiceVideoCompositor.metal"), "SpiceVideoCompositor")]
        let script = context.package.directoryURL.appending(path: "bindings/swift/Plugins/CompileMetalShaders/compile-metal.sh")
        return try sources.map { source, name in
            guard FileManager.default.fileExists(atPath: source.path()) else {
                throw PluginError.missingShader(source.path())
            }
            let air = context.pluginWorkDirectoryURL.appending(path: "\(name).air")
            let output = context.pluginWorkDirectoryURL.appending(path: "\(name).metallib")
            return .buildCommand(
                displayName: "Compile \(name)", executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path(), source.path(), air.path(), output.path()],
                inputFiles: [source, script], outputFiles: [output]
            )
        }
    }
}

private enum PluginError: Error, CustomStringConvertible {
    case missingShader(String)
    case unsupportedTarget(String)

    var description: String {
        switch self {
        case let .missingShader(path):
            "Metal shader source is missing at \(path)"
        case let .unsupportedTarget(name):
            "CompileMetalShaders can only be attached to a Swift target; got \(name)"
        }
    }
}
