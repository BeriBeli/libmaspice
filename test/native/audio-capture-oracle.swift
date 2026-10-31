import AVFAudio
import Foundation
final class CaptureOracle {
 let processor:AudioCaptureProcessor
 var drain:RecordCaptureDrain?
 init?(_ input:AVAudioFormat,_ rate:UInt32,_ channels:UInt32,_ maximum:UInt32,_ capacity:Int,_ slots:Int){
  guard let output=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:Double(rate),channels:channels,interleaved:true),let converter=AVAudioConverter(from:input,to:output),let processor=AudioCaptureProcessor(converter:converter,outputFormat:output,inputSampleRate:input.sampleRate,maximumInputFrames:maximum,ringCapacity:AudioPacketRingCapacity(capacityBytes:capacity,capacitySlots:slots)) else{return nil}
  self.processor=processor
 }
}
@_cdecl("audio_oracle_create") public func create(_ raw:UnsafeRawPointer,_ rate:UInt32,_ channels:UInt32,_ maximum:UInt32,_ capacity:Int,_ slots:Int)->UnsafeMutableRawPointer?{
 let input=Unmanaged<AVAudioFormat>.fromOpaque(raw).takeUnretainedValue()
 guard let value=CaptureOracle(input,rate,channels,maximum,capacity,slots)else{return nil}
 return Unmanaged.passRetained(value).toOpaque()
}
@_cdecl("audio_oracle_destroy") public func destroy(_ raw:UnsafeRawPointer){Unmanaged<CaptureOracle>.fromOpaque(raw).release()}
@_cdecl("audio_oracle_capture") public func capture(_ raw:UnsafeRawPointer,_ pcm:UnsafeRawPointer,_ timestamp:UInt32){let value=Unmanaged<CaptureOracle>.fromOpaque(raw).takeUnretainedValue();value.processor.capture(Unmanaged<AVAudioPCMBuffer>.fromOpaque(pcm).takeUnretainedValue(),timestamp:timestamp)}
@_cdecl("audio_oracle_drain") public func drain(_ raw:UnsafeRawPointer,_ meta:UnsafeMutablePointer<UInt64>){
 let v=Unmanaged<CaptureOracle>.fromOpaque(raw).takeUnretainedValue();let d=v.processor.drain();v.drain=d
 meta[0]=UInt64(d.packets.count);meta[1]=UInt64(d.droppedBytes)
 switch d.failureToken {case nil:meta[2]=0;case .inputFormatChanged:meta[2]=1;case .invalidInputStorage:meta[2]=2;case .converter:meta[2]=3;case .invalidOutputStorage:meta[2]=4}
 let s=v.processor.diagnostics();meta[3]=s.inputCallbacks;meta[4]=s.inputFrames;meta[5]=s.splitInputCallbacks;meta[6]=s.conversionPasses;meta[7]=s.conversionFailures;meta[8]=s.convertedFrames
}
@_cdecl("audio_oracle_packet") public func packet(_ raw:UnsafeRawPointer,_ index:Int,_ output:UnsafeMutableRawPointer,_ capacity:Int,_ meta:UnsafeMutablePointer<UInt64>)->Int32 {
 let v=Unmanaged<CaptureOracle>.fromOpaque(raw).takeUnretainedValue();guard let d=v.drain,index<d.packets.count else{return -1}
 let p=d.packets[index];guard p.data.count<=capacity else{return -1};p.data.copyBytes(to:output.assumingMemoryBound(to:UInt8.self),count:p.data.count);meta[0]=UInt64(p.timestamp);meta[1]=UInt64(p.data.count);return 0
}
