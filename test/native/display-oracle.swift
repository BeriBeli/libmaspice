import Foundation
import SpiceWire
@main struct DisplayOracle {
    struct Input:Decodable{let kind:UInt16;let data:Data}
    static func main()throws{
        let inputs=try JSONDecoder().decode([Input].self,from:FileHandle.standardInput.readDataToEndOfFile())
        let decoder=SpiceDisplayWireDecoder()
        let results=inputs.map {input -> Bool in do{switch input.kind {
        case 122: _=try decoder.decodeStreamCreateMessage(input.data)
        case 123: _=try decoder.decodeStreamDataMessage(input.data)
        case 124: _=try decoder.decodeStreamClipMessage(input.data)
        case 125: _=try decoder.decodeStreamDestroyMessage(input.data)
        case 126: try decoder.decodeStreamDestroyAllMessage(input.data)
        case 316: _=try decoder.decodeStreamDataSizedMessage(input.data)
        case 317: _=try SpiceDisplayMonitorCodec.decode(input.data)
        default: _=try decoder.decode(id:input.kind,body:input.data)
        };return true}catch{return false}}
        FileHandle.standardOutput.write(try JSONEncoder().encode(results))
    }
}
