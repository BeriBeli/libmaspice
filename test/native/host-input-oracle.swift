import AppKit
@main struct Oracle {
 @MainActor static func main() throws {
  let input=try JSONSerialization.jsonObject(with:FileHandle.standardInput.readDataToEndOfFile()) as! [String:Any]
  let view=OracleView();var output:[Any]=[]
  for row in input["commands"] as! [[UInt64]] {
   let op=row[0];view.output=[]
   if op==3 {_=view.resignFirstResponder();output.append(view.output);continue}
   let event=NSEvent.keyEvent(with:op==0 ? .keyDown : (op==1 ? .keyUp : .flagsChanged),location:.zero,modifierFlags:.init(rawValue:UInt(row[2])),timestamp:0,windowNumber:0,context:nil,characters:row[3]==0 ? "x" : ".",charactersIgnoringModifiers:row[3]==0 ? "x" : ".",isARepeat:false,keyCode:UInt16(row[1]))!
   if op<2 && MacXTScanCode.scanCode(for:event)==nil {output.append(NSNull());continue}
   switch op {case 0:view.keyDown(with:event);case 1:view.keyUp(with:event);default:view.flagsChanged(with:event)}
   output.append(view.output)
  }
  var geometry:[[Double]]=[]
  for row in input["geometry"] as! [[Double]] {
   let w=Int(row[4]),h=Int(row[5]);let rect=Drawing.contentRectangle(in:NSRect(x:row[0],y:row[1],width:row[2],height:row[3]),frameWidth:w,frameHeight:h)
   let point=NSPoint(x:row[6],y:row[7]);var result:[Double]=[Double(rect.minX),Double(rect.minY),Double(rect.width),Double(rect.height),-1,-1]
   if rect.contains(point) {
    result[4]=Double(min(w-1,max(0,Int(((point.x-rect.minX)/rect.width)*CGFloat(w)))))
    result[5]=Double(min(h-1,max(0,Int(((point.y-rect.minY)/rect.height)*CGFloat(h)))))
   }
   geometry.append(result)
  }
  let data=try JSONSerialization.data(withJSONObject:["commands":output,"geometry":geometry],options:[.sortedKeys]);FileHandle.standardOutput.write(data)
 }
}
