import Foundation
import SwiftSpice

func announce(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
func request(_ text: String) -> Data { Data(text.utf8) }
func status(_ bytes: Data, _ code: Int) -> Bool {
    bytes.starts(with: Data("HTTP/1.1 \(code) ".utf8))
}
@main struct Consumer {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let ports = arguments.dropFirst(2).map { UInt16($0)! }
        let session = SpiceSession()
        for run in 0..<2 {
            var server: SpiceWebDAVServer? = try .init(root: root, maximumClients: 2, maximumHeaderBytes: 128, maximumBodyBytes: 64)
            precondition(server!.root == root.standardizedFileURL.resolvingSymlinksInPath())
            precondition(server!.accessMode == .readOnly)
            let prefix = try await server!.receive(clientID: 1, data: request("GET /file HTTP/1.1\r\n"))
            precondition(prefix.isEmpty)
            _ = try await session.connect(endpoint: .init(host: "127.0.0.1", port: ports[run]), credentials: .init(password: "synthetic-test"))
            // Failure must leave the supplied server's prior parser state intact.
            do { try await session.attachWebDAVServer(server!, channelID: 0); preconditionFailure("missing channel") }
            catch SpiceError.protocolError { }
            try await session.attachWebDAVServer(server!, channelID: 3)
            try await session.attachWebDAVServer(server!, channelID: 4)
            do { try await session.attachWebDAVServer(server!, channelID: 3); preconditionFailure("duplicate server") }
            catch SpiceError.protocolError { }
            announce("attached \(run)")
            precondition(readLine() == "check")
            do { _ = try await server!.receive(clientID: 2, data: request("GET /file HTTP/1.1\r\n\r\n")); preconditionFailure("mixed client") }
            catch SpiceWebDAVServerError.invalidRequest { }
            do { _ = try await server!.receive(clientID: 3, data: request("GET /file HTTP/1.1\r\n\r\n")); preconditionFailure("unshared client bound") }
            catch SpiceWebDAVServerError.tooManyClients { }
            let completed = try await server!.receive(clientID: 1, data: request("\r\n"))
            precondition(completed.count == 1 && completed[0].suffix(5) == request("hello"))
            await server!.close(clientID: 1)
            if run == 1 { server = nil }
            announce("checked \(run)")
            precondition(readLine() == "done")
            await session.disconnect()
            if let server {
                // The peer left an incomplete prefix before disconnect. Reuse
                // must start fresh, keeping the same server/root/limits.
                let fresh = try await server.receive(clientID: 2, data: request("GET /file HTTP/1.1\r\n\r\n"))
                precondition(fresh.count == 1 && status(fresh[0], 200))
                await server.closeAll()
                let pipeline = String(repeating: "HEAD /file HTTP/1.1\r\n\r\n", count: 70)
                let heads = try await server.receive(clientID: 1, data: request(pipeline))
                precondition(heads.count == 70 && heads.allSatisfy { status($0, 200) && $0.suffix(4) == request("\r\n\r\n") })
                await server.closeAll()
                do { _ = try await server.receive(clientID: 1, data: request(String(repeating: "X", count: 129))); preconditionFailure("header limit") }
                catch SpiceWebDAVServerError.headerTooLarge { }
                await server.closeAll()
                do { _ = try await server.receive(clientID: 1, data: request("PUT /file HTTP/1.1\r\nContent-Length: 65\r\n\r\n")); preconditionFailure("body limit") }
                catch SpiceWebDAVServerError.bodyTooLarge { }
                await server.closeAll()
            }
            announce("stopped \(run)")
        }
        let writer = try SpiceWebDAVServer(root: root, accessMode: .readWrite)
        let written = try await writer.receive(clientID: 1, data: request("PUT /created HTTP/1.1\r\nContent-Length: 3\r\n\r\nnew"))
        precondition(written.count == 1 && status(written[0], 201))
        let contents = try Data(contentsOf: root.appending(path: "created"))
        precondition(contents == request("new"))
        announce("Swift WebDAV shared ownership, bounds, exact bytes and reconnect passed")
    }
}
