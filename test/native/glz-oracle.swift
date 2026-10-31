// Independent oracle built directly from the unchanged Swift sources.
import Foundation
@main struct GLZOracle {
    struct Input:Decodable {let data:Data;let width:Int;let height:Int;let reset:Bool}
    struct Output:Encodable {let status:Int;let pixels:Data?;let flags:Int?}
    static func main() async throws {
        let inputs=try JSONDecoder().decode([Input].self,from:FileHandle.standardInput.readDataToEndOfFile())
        let decoder=SpiceGLZDecoder(limits:.init(maximumPendingDictionaryWaits:0))
        var outputs:[Output]=[]
        for input in inputs {
            if input.reset {await decoder.clear()}
            do {let image=try await decoder.decode(descriptor:.init(width:input.width,height:input.height),payload:input.data)
                outputs.append(.init(status:0,pixels:image.pixelsBGRA,flags:(image.topDown ? 1:0)|(image.alphaMode == .straight ? 2:0)))
            } catch {outputs.append(.init(status:-1,pixels:nil,flags:nil))}
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(outputs))
    }
}
