import Foundation
import SpiceWire
@main struct PeripheralOracle {
    struct Input:Decodable {let kind:UInt16;let data:Data}
    static func main() throws {
        let inputs=try JSONDecoder().decode([Input].self,from:FileHandle.standardInput.readDataToEndOfFile())
        let results=inputs.map { input -> Bool in do {
            switch input.kind {
            case 8: _=try SpiceSmartcardWireCodec().decode(input.data)
            case 9: _=try SpiceVMCWireCodec().decodeServer(id:101,body:input.data)
            case 201: _=try SpicePortWireCodec().decodeInitialization(input.data)
            case 202: _=try SpicePortWireCodec().decodeEvent(input.data)
            default:return false
            };return true
        } catch {return false} }
        FileHandle.standardOutput.write(try JSONEncoder().encode(results))
    }
}
