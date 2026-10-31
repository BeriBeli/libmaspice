// Compiled against unchanged Swift decoder sources and native pixel kernels.
import Foundation

@main
struct LZOracle {
    struct Input: Decodable {
        let data: Data
        let width: Int
        let height: Int
        let palette: [UInt32]?
    }
    struct Output: Encodable {
        let status: Int
        let pixels: Data?
        let flags: Int?
    }
    static func main() async throws {
        let inputs = try JSONDecoder().decode([Input].self, from: FileHandle.standardInput.readDataToEndOfFile())
        var results: [Output] = []
        for input in inputs {
            do {
                let decoder = SpiceLZDecoder()
                let descriptor = SpiceCodecImageDescriptor(width: input.width, height: input.height)
                let image: SpiceDecodedImage
                if let palette = input.palette {
                    image = try await decoder.decodePalette(descriptor: descriptor, payload: input.data,
                        palette: SpiceLZPalette(uniqueID: 0, entriesARGB: palette))
                } else {
                    image = try await decoder.decode(descriptor: descriptor, payload: input.data)
                }
                results.append(Output(status: 0, pixels: image.pixelsBGRA,
                    flags: (image.topDown ? 1 : 0) | (image.alphaMode == .straight ? 2 : 0)))
            } catch {
                results.append(Output(status: -1, pixels: nil, flags: nil))
            }
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(results))
    }
}
