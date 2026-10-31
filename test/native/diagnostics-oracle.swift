import Foundation
// Fixture clock conversion is identity so the exact assembler receives explicit,
// deterministic host nanoseconds. Clock conversion itself is tested separately.
package struct DisplayFrameSourceTiming { let messageReceivedAt:UInt64;let surfaceReadyAt:UInt64 }
package enum SpiceInteractionHostClock { static func nanoseconds(for value:UInt64)->UInt64? { value } }
// Data carriers for the unmodified marker ROI algorithm; no alternate decoder.
struct MarkerPixels {
 let width:Int; let height:Int; let bytesPerRow:Int; let data:Data
 func withReadOnlyPixelBytes<T>(_ body:(UnsafeRawPointer,Int,Int)->T)->T? { data.withUnsafeBytes { body($0.baseAddress!,bytesPerRow,$0.count) } }
}
package struct SpiceDesktopSnapshot {
 struct Update { let frame:MarkerPixels }
 let frame:Update?
 let interactionFrameIdentity:SpiceInteractionFrameIdentity?
}
@main enum Main {
 static func main() throws {
  var histograms=[SpiceTimingHistogram(),SpiceTimingHistogram(),SpiceTimingHistogram()]
  let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
  while let line=readLine() {
   let input=try JSONSerialization.jsonObject(with:Data(line.utf8)) as! [String:Any]
   let mode=input["mode"] as! String
   if mode=="trace" {
    let trace=SpiceInteractionTraceAssembler(pairId:"pair",version:"zig",runId:"run",order:1,actionClass:.click,token:"0123456789abcdef",checksum:0xaabbccdd)
    for command in input["commands"] as! [[NSNumber]] {
     let v=command.map{$0.uint64Value};let op=v[0],n=v[1],x=v[2],y=v[3],z=v[4],w=v[5]
     let id=SpiceInteractionFrameIdentity(desktopGeneration:n/100+1,displayChannelID:UInt8(n%2),surfaceID:UInt32(n%3),surfaceGeneration:n/10+1,frameRevision:n,deliverySequence:n+1)
     switch op {
     case 0:trace.recordHostInput(scheduledNs:x,hostInputNs:y,sendStartedNs:z)
     case 1:trace.recordSendCompleted(at:x,motionAckNs:y==UInt64.max ? nil:y)
     case 2:trace.recordMotionAcknowledged(at:x)
     case 3:trace.recordGuestEvidence(receivedNs:x,drawnNs:y,markerRevision:z)
     case 4:
      let payload=SpiceInteractionMarkerPayload(token:"0123456789abcdef",markerRevision:y,checksum:0xaabbccdd)
      let placements:[SpiceInteractionMarkerPlacement]=x==0 ? []:x==1 ? [.init(payload:payload,originX:8,originY:8)]:[.init(payload:payload,originX:8,originY:8),.init(payload:payload,originX:8,originY:24)]
      let pixels=MarkerPixels(width:400,height:48,bytesPerRow:1600,data:SpiceInteractionMarkerROIDetector.renderForTesting(placements:placements,frameWidth:400,frameHeight:48,bytesPerRow:1600))
      trace.observeFrame(snapshot:SpiceDesktopSnapshot(frame:.init(frame:pixels),interactionFrameIdentity:id),sourceTiming:z==UInt64.max || w==UInt64.max ? nil:DisplayFrameSourceTiming(messageReceivedAt:z,surfaceReadyAt:w))
     case 5:trace.observeSelected(identity:id,readyNs:x,selectionNs:y)
     case 6:trace.observeCommitted(identity:id,at:x)
     case 7:_=trace.observePresented(identity:id,at:x)
     case 8:trace.observePresentationDropped(identity:id)
     case 9:trace.retireSurfaceLifecycle(displayChannelID:id.displayChannelID,surfaceID:id.surfaceID,generation:x)
     case 10:trace.retireDesktopGeneration(x)
     default:fatalError("invalid command")
     }
    }
    print(try encoder.encode(trace.finish()).base64EncodedString())
   } else if mode=="histogram" {
    let op=input["op"] as! Int, slot=input["slot"] as! Int
    switch op {
    case 0:histograms[slot].record(Duration(secondsComponent:(input["seconds"] as! NSNumber).int64Value,attosecondsComponent:(input["attoseconds"] as! NSNumber).int64Value))
    case 1:histograms[slot].accumulate(histograms[input["other"] as! Int])
    default:histograms[slot]=SpiceTimingHistogram()
    }
    let result=histograms[slot].summary
    print(String(decoding:try JSONEncoder().encode([Double(result.sampleCount),result.p95Milliseconds ?? -1,result.maximumMilliseconds ?? -1]),as:UTF8.self))
   } else if mode=="marker" {
    let identity=SpiceInteractionFrameIdentity(desktopGeneration:1,displayChannelID:0,surfaceID:0,surfaceGeneration:1,frameRevision:1,deliverySequence:1)
    let pixels=MarkerPixels(width:input["width"] as! Int,height:input["height"] as! Int,bytesPerRow:input["stride"] as! Int,data:Data(base64Encoded:input["pixels"] as! String)!)
    let result=SpiceInteractionMarkerROIDetector.detect(in:SpiceDesktopSnapshot(frame:.init(frame:pixels),interactionFrameIdentity:identity),expectedToken:input["token"] as! String,expectedChecksum:(input["checksum"] as! NSNumber).uint32Value)
    var output:[UInt64]=[0,0,0,0]
    switch result {case .none:break;case let .ambiguous(count):output=[2,UInt64(count),0,0];case let .exact(payload,_):output=[1,UInt64(payload.token,radix:16)!,payload.markerRevision,UInt64(payload.checksum)]}
    print(String(decoding:try JSONEncoder().encode(output),as:UTF8.self))
   } else {
    let bytes=Data(base64Encoded:input["record"] as! String)!
    do {
     let record:SpiceInteractionTraceRecord
     if mode=="decode" {record=try JSONDecoder().decode(SpiceInteractionTraceRecord.self,from:bytes)}
     else {
      let d=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
      func text(_ key:String)->String? {d[key] as? String}
      func number(_ key:String)->UInt64? {(d[key] as? NSNumber)?.uint64Value}
      record=SpiceInteractionTraceRecord(pairId:text("pair_id")!,version:text("version")!,runId:text("run_id")!,order:number("order")!,actionClass:SpiceInteractionActionClass(rawValue:text("action_class")!)!,token:text("token")!,scheduledNs:number("scheduled_ns"),hostInputNs:number("host_input_ns"),sendStartedNs:number("send_started_ns"),sendCompletedNs:number("send_completed_ns"),motionAckNs:number("motion_ack_ns"),guestReceivedNs:number("guest_received_ns"),guestMarkerDrawnNs:number("guest_marker_drawn_ns"),displayReceiveNs:number("display_receive_ns"),surfaceReadyNs:number("surface_ready_ns"),selectedRevisionReadyNs:number("selected_revision_ready_ns"),selectionNs:number("selection_ns"),metalCommitNs:number("metal_commit_ns"),presentedNs:number("presented_ns"),displayChannelID:number("display_channel_id").map{UInt8($0)},surfaceID:number("surface_id").map{UInt32($0)},surfaceGeneration:number("surface_generation"),desktopGeneration:number("desktop_generation"),frameRevision:number("frame_revision"),deliverySequence:number("delivery_sequence"),markerRevision:number("marker_revision"),markerChecksum:text("marker_checksum"),invalidReason:text("invalid_reason"))
     }
     print(try encoder.encode(record).base64EncodedString())
    } catch {print("error")}
   }
  }
 }
}
