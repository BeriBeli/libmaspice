import Foundation
@main struct AnnexBOracle {
    struct Input:Decodable { let codec:Int; let bytes:Data }
    static func main() throws {
        let inputs=try JSONDecoder().decode([Input].self,from:FileHandle.standardInput.readDataToEndOfFile())
        let parser=SpiceAnnexBParser()
        let outputs=inputs.map { input -> Data? in
            guard let unit=try? parser.parse(codec:input.codec==0 ? .h264:.h265,payload:input.bytes) else {return nil}
            var output=Data([unit.containsPicture ? 1:0,unit.isRandomAccess ? 1:0])
            func write(_ value:Int){let n=UInt32(value);output.append(contentsOf:[UInt8(truncatingIfNeeded:n),UInt8(truncatingIfNeeded:n>>8),UInt8(truncatingIfNeeded:n>>16),UInt8(truncatingIfNeeded:n>>24)])}
            write(unit.nalUnits.count);write(unit.sampleData.count);output.append(unit.sampleData)
            for nal in unit.nalUnits {output.append(nal.type);write(nal.bytes.count);output.append(nal.bytes)}
            return output
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(outputs))
    }
}
