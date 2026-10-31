import CoreVideo
import Foundation
import SpiceCodecs
@main struct VideoOracle {
 struct Input:Decodable{let width:Int;let height:Int;let full:Bool;let matrix:Int;let y:Data;let uv:Data}
 static func main()throws{
  let inputs=try JSONDecoder().decode([Input].self,from:FileHandle.standardInput.readDataToEndOfFile());var outputs:[Data]=[]
  for i in inputs {
   var buffer:CVPixelBuffer?
   guard CVPixelBufferCreate(nil,i.width,i.height,i.full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,nil,&buffer)==kCVReturnSuccess,let buffer else{throw NSError(domain:"CV",code:1)}
   guard CVPixelBufferLockBaseAddress(buffer,[])==kCVReturnSuccess else{throw NSError(domain:"CV",code:2)}
   for (plane,data,rowBytes,rows) in [(0,i.y,i.width,i.height),(1,i.uv,((i.width+1)/2)*2,(i.height+1)/2)] {
    let base=CVPixelBufferGetBaseAddressOfPlane(buffer,plane)!,stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,plane)
    data.withUnsafeBytes{bytes in for y in 0..<rows {base.advanced(by:y*stride).copyMemory(from:bytes.baseAddress!.advanced(by:y*rowBytes),byteCount:rowBytes)}}
   }
   CVPixelBufferUnlockBaseAddress(buffer,[])
   let matrix:CFString?=switch i.matrix {case 601:kCVImageBufferYCbCrMatrix_ITU_R_601_4;case 709:kCVImageBufferYCbCrMatrix_ITU_R_709_2;case 2020:kCVImageBufferYCbCrMatrix_ITU_R_2020;default:nil}
   if let matrix{CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,matrix,.shouldPropagate)}
   let frame=try SpiceVideoToolboxFrame(pixelBuffer:buffer,expectedWidth:i.width,expectedHeight:i.height,maximumDecodedBytes:256*1024*1024)
   outputs.append(try frame.copyBGRA().pixelsBGRA)
  }
  FileHandle.standardOutput.write(try JSONEncoder().encode(outputs))
 }
}
