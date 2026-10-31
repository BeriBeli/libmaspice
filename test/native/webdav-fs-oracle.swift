import Foundation
struct Input:Decodable {let root:String;let write:Bool;let limit:Int;let requests:[[UInt8]]}
struct Observation:Encodable {let status:Int;let bytes:[UInt8]}
@main enum Main {
 static func main()async throws{
  while let line=readLine(){
   let input=try JSONDecoder().decode(Input.self,from:Data(line.utf8))
   let server=try SpiceWebDAVServer(root:URL(fileURLWithPath:input.root),accessMode:input.write ? .readWrite:.readOnly,maximumBodyBytes:input.limit)
   var results:[Observation]=[]
   for (i,bytes) in input.requests.enumerated(){
    do {let responses=try await server.receive(clientID:Int64(i),data:Data(bytes));results.append(Observation(status:responses.isEmpty ? 0:1,bytes:responses.flatMap{Array($0)}))}
    catch{let code:Int;switch error{case .invalidRequest:code = -1;case .headerTooLarge:code = -2;case .bodyTooLarge:code = -3;default:code = -9};results.append(Observation(status:code,bytes:[]))}
    await server.close(clientID:Int64(i))
   }
   print(String(decoding:try JSONEncoder().encode(results),as:UTF8.self))
  }
 }
}
