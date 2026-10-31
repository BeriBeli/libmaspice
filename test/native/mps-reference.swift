// Independent implementation of the existing Swift presenter's MPS setup:
// BGRA8Unorm, MPSImageLanczosScale, clamp edges, default scale transform.
import Foundation
import Metal
import MetalPerformanceShaders
@main struct MPSReference {
    struct Input:Decodable{let width:Int;let height:Int;let targetWidth:Int;let targetHeight:Int;let pixels:Data}
    static func main()throws{
        let inputs=try JSONDecoder().decode([Input].self,from:FileHandle.standardInput.readDataToEndOfFile())
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue()else{throw NSError(domain:"Metal",code:1)}
        var outputs:[Data]=[]
        for input in inputs {
            func texture(_ w:Int,_ h:Int)throws -> any MTLTexture {
                let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:w,height:h,mipmapped:false)
                descriptor.storageMode = .shared;descriptor.usage=[.shaderRead,.shaderWrite,.renderTarget]
                guard let texture=device.makeTexture(descriptor:descriptor)else{throw NSError(domain:"Metal",code:2)};return texture
            }
            let source=try texture(input.width,input.height),target=try texture(input.targetWidth,input.targetHeight)
            input.pixels.withUnsafeBytes{source.replace(region:MTLRegionMake2D(0,0,input.width,input.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:input.width*4)}
            let filter=MPSImageLanczosScale(device:device);filter.edgeMode = .clamp
            guard let command=queue.makeCommandBuffer()else{throw NSError(domain:"Metal",code:3)}
            filter.encode(commandBuffer:command,sourceTexture:source,destinationTexture:target);command.commit();command.waitUntilCompleted()
            guard command.status == .completed,command.error==nil else{throw NSError(domain:"Metal",code:4)}
            var output=Data(count:input.targetWidth*input.targetHeight*4)
            output.withUnsafeMutableBytes{target.getBytes($0.baseAddress!,bytesPerRow:input.targetWidth*4,from:MTLRegionMake2D(0,0,input.targetWidth,input.targetHeight),mipmapLevel:0)};outputs.append(output)
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(outputs))
    }
}
