import Foundation
import SpiceWire
@main struct CursorOracle {
    struct Input:Decodable {let kind:UInt16;let data:Data}
    static func main() throws {
        let inputs=try JSONDecoder().decode([Input].self,from:FileHandle.standardInput.readDataToEndOfFile())
        let decoder=SpiceCursorWireDecoder()
        let results=inputs.map { input -> Bool in do {_=try decoder.decode(id:input.kind,body:input.data);return true} catch {return false} }
        FileHandle.standardOutput.write(try JSONEncoder().encode(results))
    }
}
