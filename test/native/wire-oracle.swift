// Compiled directly with the unchanged SpiceWire sources, never linked to Zig.
import Foundation

@main
struct WireOracle {
    struct Input: Decodable {
        let mode: Int
        let chunks: [[UInt8]]
        let maximum: Int
    }
    struct Logical: Encodable { let type: UInt16; let body: [UInt8] }
    struct Output: Encodable { let status: Int; let serial: UInt64?; let messages: [Logical]; let buffered: Int }
    static func main() throws {
        let inputs = try JSONDecoder().decode([Input].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let results = inputs.map { input -> Output in
            var framer = MessageFramer(mode: input.mode == 0 ? .full : .mini)
            do {
                for chunk in input.chunks { try framer.append(Data(chunk)) }
                guard let batch = try framer.nextBatch(maximumSubmessages: input.maximum) else {
                    return Output(status: 0, serial: nil, messages: [], buffered: framer.bufferedByteCount)
                }
                return Output(status: 1, serial: batch.serial, messages: batch.logicalMessages.map {
                    Logical(type: $0.type, body: Array(batch.body(for: $0)))
                }, buffered: framer.bufferedByteCount)
            } catch {
                let code: Int
                switch error {
                case WireError.truncated: code = -3
                case WireError.invalidOffset: code = -4
                case WireError.integerOverflow: code = -5
                case WireError.messageTooLarge: code = -6
                case WireError.tooManySegments: code = -7
                case WireError.invalidSize: code = -8
                default: code = -1
                }
                return Output(status: code, serial: nil, messages: [], buffered: framer.bufferedByteCount)
            }
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(results))
    }
}
