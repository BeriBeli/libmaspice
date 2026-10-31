import Foundation
struct Input:Decodable {let bytes:[UInt8];let header:Int;let body:Int;let sequence:UInt64}
struct Result:Encodable {let status:Int;let meta:[UInt64];let bytes:[UInt8]}
extension HTTPOracle {
 func run(_ input:Input)->Result {
  do {
   guard let parsed=try nextRequest(buffer:Data(input.bytes),sequence:input.sequence) else{return Result(status:0,meta:[],bytes:[])}
   let r=parsed.request
   var bytes:[UInt8]=[]
   func append(_ data:[UInt8]) {let n=UInt64(data.count);for shift in stride(from:0,to:64,by:8){bytes.append(UInt8(truncatingIfNeeded:n>>shift))};bytes += data}
   append(Array(r.method.utf8));append(Array(r.target.utf8));append(Array(r.body))
   let headers=r.headers.map{($0.key.precomposedStringWithCanonicalMapping,$0.value)}.sorted{Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8))}
   for (key,value) in headers {append(Array(key.utf8));append(Array(value.utf8))}
   return Result(status:1,meta:[UInt64(parsed.consumedBytes),UInt64(r.inputRetainedByteCount),UInt64(r.responseRetainedByteLimit),r.sequence,UInt64(r.headers.count),UInt64(bytes.count)],bytes:bytes)
  }catch {let code:Int;switch error {case .headerTooLarge:code = -2;case .bodyTooLarge:code = -3;default:code = -1};return Result(status:code,meta:[],bytes:[])}
 }
}
@main enum Main {
 static func main()throws{while let line=readLine(){let input=try JSONDecoder().decode(Input.self,from:Data(line.utf8));let parser=HTTPOracle(header:input.header,body:input.body);print(String(decoding:try JSONEncoder().encode(parser.run(input)),as:UTF8.self))}}
}
