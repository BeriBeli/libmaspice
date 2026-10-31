import Foundation
import SpiceWire
@main struct AudioOracle {
    struct Input:Decodable {let record:Bool;let kind:UInt16;let data:Data}
    static func main() throws {
        let inputs=try JSONDecoder().decode([Input].self,from:FileHandle.standardInput.readDataToEndOfFile())
        let playback=SpicePlaybackWireDecoder(),record=SpiceRecordWireCodec()
        let results=inputs.map { input -> Bool in do {
            if input.record {_=try record.decodeServer(id:input.kind,body:input.data)}
            else {_=try playback.decode(id:input.kind,body:input.data)}
            return true
        } catch {return false} }
        FileHandle.standardOutput.write(try JSONEncoder().encode(results))
    }
}
