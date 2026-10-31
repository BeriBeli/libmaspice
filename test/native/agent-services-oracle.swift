import Foundation
import SpiceWire
import SpiceProtocol
@main struct AgentServicesOracle {
    struct Input:Decodable {let op:UInt32;let value:Int64;let kind:UInt32;let data:Data}
    struct Request:Decodable {let mode:String;let inputs:[Input]}
    static func main() throws {
        let request=try JSONDecoder().decode(Request.self,from:FileHandle.standardInput.readDataToEndOfFile())
        var state=ClipboardStateMachine(maximumTextBytes:32)
        var outputs:[Data]=[]
        var coordinator=DisplayConfigurationCoordinator()
        for input in request.inputs {
            var writer=ByteWriter()
            if request.mode=="layout" {
                do {
                    var peer=ClipboardStateMachine(maximumTextBytes:32);_=peer.connected()
                    if input.value != 0 {_=try peer.receive(.announceCapabilities(requestReply:false,capabilities:VDAgentCapabilities(words:[input.kind])))}
                    var reader=try ByteReader(input.data);let count=try reader.readUInt32LE();guard count<=256 else {throw CocoaError(.coderReadCorrupt)}
                    var monitors:[SpiceMonitorConfiguration]=[]
                    for _ in 0..<count {let id=Int64(bitPattern:try reader.readUInt64LE());let x=Int64(bitPattern:try reader.readUInt64LE());let y=Int64(bitPattern:try reader.readUInt64LE());let width=Int64(bitPattern:try reader.readUInt64LE());let height=Int64(bitPattern:try reader.readUInt64LE());monitors.append(.init(id:Int(id),x:Int(x),y:Int(y),width:Int(width),height:Int(height)))}
                    try reader.requireFullyConsumed();writer.writeBytes(try LayoutOracleHost(state:peer).encode(.init(monitors:monitors)))
                } catch {writer.writeUInt8(255)}
            } else if request.mode=="coordinator" {
                var reply:SpiceDisplayConfiguration?
                switch input.op {
                case 0:coordinator.queue(.init(width:Int(input.value),height:480))
                case 1:if let next=coordinator.nextToSend {coordinator.didSend(next)}
                case 2:reply=coordinator.didReceiveReply()
                case 3:coordinator.disconnected()
                case 4:coordinator.discardDesired()
                case 5:coordinator.reset()
                default:break
                }
                for configuration in [coordinator.desired,coordinator.inFlight,reply] {writer.writeUInt64LE(UInt64(bitPattern:Int64(configuration?.monitors.first?.width ?? -1)))}
            } else if request.mode=="parse" {
                var status:Int32=0
                do {
                    let m=VDAgentMessage(protocolID:UInt32(input.value),type:input.kind,data:input.data)
                    if try VDAgentClipboardCodec.decode(m) != nil {status=1}
                    else if try VDAgentFileTransferCodec().decode(m) != nil {status=2}
                    else if try VDAgentMonitorCodec.decodeReply(m) != nil {status=3}
                } catch {status = -1}
                writer.writeInt32LE(status)
            } else if request.mode=="names" {
                do {guard String(data:input.data,encoding:.utf8) != nil else {throw CocoaError(.fileReadInapplicableStringEncoding)}
                    writer.writeBytes(try VDAgentFileTransferCodec().encodeStart(id:7,name:String(decoding:input.data,as:UTF8.self),size:123).data)
                } catch {writer.writeUInt8(255)}
            } else {
                var actions:[ClipboardStateMachine.Action]=[]
                var status:Int32=0
                do {
                    switch input.op {
                    case 0:actions=state.connected()
                    case 1:actions=state.disconnected()
                    case 2:actions=state.setClipboardEnabled(input.value != 0)
                    case 3:if input.kind==6 {state.didSend(.announceCapabilities(requestReply:false,capabilities:.utf8Clipboard))}
                    case 4:if let command=try VDAgentClipboardCodec.decode(VDAgentMessage(protocolID:UInt32(input.value),type:input.kind,data:input.data)){actions=try state.receive(command)}
                    case 5, 8:
                        if input.kind==0 {actions=state.localPasteboardChanged(changeCount:Int(input.value),text:nil)}
                        else {guard String(data:input.data,encoding:.utf8) != nil else {throw SpiceClipboardError.invalidUTF8};actions=state.localPasteboardChanged(changeCount:Int(input.value),text:String(decoding:input.data,as:UTF8.self))}
                    case 6:state.didWriteGuestText(changeCount:Int(input.value))
                    case 7:actions=state.announcementIfNeeded()
                    default:break
                    }
                } catch let failure as ClipboardStateMachineFailure {
                    switch failure.category {
                    case .agentDisconnected:status = -2
                    case .clipboardNotReady:status = -3
                    case .unsolicitedData:status = -4
                    case .unexpectedType:status = -5
                    case .oversizedGuestText:status = -6
                    case .invalidUTF8:status = -7
                    default:status = -1
                    }
                } catch SpiceClipboardError.invalidUTF8 {status = -7} catch {status = -1}
                writer.writeInt32LE(status)
                let flags=[state.isReady,state.isAgentConnected,state.hasExplicitPeerCapabilities,state.supportsMonitorConfiguration,state.supportsSparseMonitorConfiguration,state.supportsMonitorPositions,state.hasFileTransferCapabilityState,state.supportsFileTransfer,state.supportsFileTransferDetailedErrors]
                var bits:UInt32=0;for(i,v)in flags.enumerated(){if v{bits |= 1 << i}};writer.writeUInt32LE(bits)
                func append(_ kind:UInt32,_ data:Data){writer.writeUInt32LE(kind);writer.writeUInt32LE(UInt32(data.count));writer.writeBytes(data)}
                for action in actions {
                    switch action {
                    case let .send(command):let m=try VDAgentClipboardCodec.encode(command);append(m.type,m.data)
                    case let .writeGuestText(text):append(100,Data(text.utf8))
                    case let .emit(event):switch event {
                    case .ready:append(101,Data())
                    case .unavailable:append(102,Data())
                    case let .guestText(text):append(103,Data(text.utf8))
                    case let .localTextOffered(count):var n=ByteWriter();n.writeUInt64LE(UInt64(count));append(104,n.data)
                    case let .oversizedLocalText(count,maximum):var n=ByteWriter();n.writeUInt64LE(UInt64(count));n.writeUInt64LE(UInt64(maximum));append(105,n.data)
                    case .failed:preconditionFailure("state does not emit transport failures")
                    }
                    }
                }
            }
            outputs.append(writer.data)
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(outputs))
    }
}
