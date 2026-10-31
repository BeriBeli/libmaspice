import Foundation
struct Operation:Decodable { let op:Int;let timestamp:UInt32;let bytes:[UInt8];let size:Int }
struct Case:Decodable { let capacity:Int;let slots:Int;let staged:Bool;let operations:[Operation] }
struct Observation:Encodable {let meta:[UInt64];let bytes:[UInt8]}
@main enum Main {
 static func main() throws {
  while let line=readLine() {
   let c=try JSONDecoder().decode(Case.self,from:Data(line.utf8))
   let ring=PreallocatedAudioPacketRing(capacityBytes:c.capacity,capacitySlots:c.slots,supportsStagedEnqueue:c.staged)
   var observations:[Observation]=[]
   for op in c.operations {
    var m=[UInt64](repeating:0,count:5);var output:[UInt8]=[]
    switch op.op {
    case 0,5:
     let result=op.bytes.withUnsafeBytes { bytes in
      if op.op==5 { return ring.enqueueStaged(timestamp:op.timestamp,bytes:bytes) { $0() } }
      return ring.enqueue(timestamp:op.timestamp,bytes:bytes)
     }
     switch result {case let .enqueued(p,b):m[1]=UInt64(p);m[2]=UInt64(b)
      case let .droppedOversized(n):m[0]=1;m[1]=UInt64(n)
      case let .droppedLeaseConflict(n):m[0]=2;m[1]=UInt64(n)
      case let .rejectedClosed(n):m[0]=3;m[1]=UInt64(n)}
    case 1:
     output=[UInt8](repeating:255,count:op.size);m[0]=4;m[1]=UInt64(output.withUnsafeMutableBytes{ring.read(into:$0)});m[4]=UInt64(output.count)
    case 2:
     m[0]=5;if let packet=ring.dequeue(){m[0]=6;m[3]=UInt64(packet.timestamp);output=Array(packet.data);m[4]=UInt64(output.count)}
    case 3:ring.reset()
    case 4:ring.close()
    default:fatalError("invalid fixture operation")
    }
    let d=ring.diagnostics()
    m += [UInt64(d.queuedBytes),UInt64(d.queuedSlots),d.enqueuedPackets,d.enqueuedBytes,d.dequeuedPackets,d.dequeuedBytes,d.readCalls,d.wraparoundCopies,d.underflows,d.overruns,d.droppedPackets,d.droppedBytes,d.resetCount,d.closeCount,d.dequeueLeaseStarts,d.dequeueLeaseFinishes,d.dequeueMaterializations,d.dequeueMaterializedBytes,d.dequeueLeaseConflictDrops,d.dequeueBlockedReads,d.dequeueBlockedDequeues,d.deferredResets,d.deferredCloses,UInt64(d.activeDequeueLeases),d.isClosed ? 1:0,UInt64(d.preallocatedBytes),UInt64(d.preallocatedStagingBytes),UInt64(d.capacitySlots)]
    observations.append(Observation(meta:m,bytes:output))
   }
   print(String(decoding:try JSONEncoder().encode(observations),as:UTF8.self))
  }
 }
}
