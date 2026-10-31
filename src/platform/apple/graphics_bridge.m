// Apple-object adapter only. Geometry, budgets, sequencing and publication live
// in Zig. Reuses the existing Metal kernel; no replacement color/scaling policy.
#import "graphics_bridge.h"
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <simd/simd.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdatomic.h>
#include <mach/mach_time.h>
@interface SZGraphics : NSObject { @public _Atomic(uint64_t) submitted; }
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) id<MTLCommandQueue> queue;
@property(nonatomic,strong) id<MTLComputePipelineState> bgra;
@property(nonatomic,strong) id<MTLComputePipelineState> nv12;
@property(nonatomic,strong) id textureCacheOwner;
@end
@implementation SZGraphics
@end
@interface SZFrame : NSObject
@property(nonatomic,strong) id surfaceOwner;
@property(nonatomic,readonly) IOSurfaceRef surface;
@property(nonatomic,strong) id<MTLTexture> texture;
@end
@implementation SZFrame
- (IOSurfaceRef)surface { return (__bridge IOSurfaceRef)_surfaceOwner; }
@end
void *spice_zig_graphics_create(const char *path) {
    @autoreleasepool {
        if (!path) return NULL;
        SZGraphics *g=[SZGraphics new];g.device=MTLCreateSystemDefaultDevice();
        if (!g.device) return NULL;
        g.queue=[g.device newCommandQueue];
        NSString *filename=[[NSString alloc] initWithUTF8String:path];
        if (!filename) return NULL;
        NSError *error=nil;
        id<MTLLibrary> library=[g.device newLibraryWithURL:[NSURL fileURLWithPath:filename] error:&error];
        if (!library || !g.queue) return NULL;
        id<MTLFunction> function=[library newFunctionWithName:@"spice_bgra_to_bgra"];
        if (!function) return NULL;
        g.bgra=[g.device newComputePipelineStateWithFunction:function error:&error];
        if (!g.bgra) return NULL;
        function=[library newFunctionWithName:@"spice_nv12_to_bgra"];
        if(!function)return NULL;
        g.nv12=[g.device newComputePipelineStateWithFunction:function error:&error];
        if(!g.nv12)return NULL;
        CVMetalTextureCacheRef cache=NULL;
        if(CVMetalTextureCacheCreate(NULL,NULL,g.device,NULL,&cache)!=kCVReturnSuccess || !cache)return NULL;
        g.textureCacheOwner=CFBridgingRelease(cache);
        return (__bridge_retained void *)g;
    }
}
uint64_t spice_zig_graphics_submitted(void *p) { return p?atomic_load(&((__bridge SZGraphics *)p)->submitted):0; }
void *spice_zig_graphics_device(void *p) { return p?(__bridge void *)((__bridge SZGraphics *)p).device:NULL; }
void spice_zig_graphics_retain(void *p) { if(p) CFRetain(p); }
void spice_zig_graphics_destroy(void *p) { if(p) { id object=CFBridgingRelease(p); (void)object; } }
int spice_zig_graphics_frame_layout(uint32_t width,uint32_t height,size_t *stride,size_t *size) {
    if(!stride || !size || !width || !height || width>16384 || height>16384)return -1;
    *stride=IOSurfaceAlignProperty(kIOSurfaceBytesPerRow,(size_t)width*4);
    if(*stride>SIZE_MAX/height)return -1;
    *size=IOSurfaceAlignProperty(kIOSurfaceAllocSize,*stride*height);
    return *stride && *size?0:-1;
}
size_t spice_zig_graphics_frame_size(void *p) {return p?IOSurfaceGetAllocSize(((__bridge SZFrame *)p).surface):0;}
void *spice_zig_graphics_frame_create(void *context,uint32_t width,uint32_t height) {
    @autoreleasepool {
        if(!context || !width || !height || width>16384 || height>16384) return NULL;
        SZGraphics *g=(__bridge SZGraphics *)context;
        size_t row=0,size=0;
        if(spice_zig_graphics_frame_layout(width,height,&row,&size))return NULL;
        IOSurfaceRef surface=IOSurfaceCreate((__bridge CFDictionaryRef)@{
            (id)kIOSurfaceWidth:@(width),(id)kIOSurfaceHeight:@(height),
            (id)kIOSurfaceBytesPerElement:@4,(id)kIOSurfaceBytesPerRow:@(row),
            (id)kIOSurfaceAllocSize:@(size),(id)kIOSurfacePixelFormat:@((uint32_t)0x42475241)
        });
        if(!surface)return NULL;
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite|MTLTextureUsageRenderTarget;
        id<MTLTexture> texture=[g.device newTextureWithDescriptor:d iosurface:surface plane:0];
        if(!texture){CFRelease(surface);return NULL;}
        SZFrame *frame=[SZFrame new];frame.surfaceOwner=CFBridgingRelease(surface);frame.texture=texture;
        return (__bridge_retained void *)frame;
    }
}
void spice_zig_graphics_frame_destroy(void *p) { if(p){id object=CFBridgingRelease(p);(void)object;} }
int spice_zig_graphics_frame_lock(void *p,int writing,uint8_t **bytes,size_t *stride,size_t *size) {
    if(!p || !bytes || !stride || !size)return -1;
    *bytes=NULL;*stride=0;*size=0;SZFrame *frame=(__bridge SZFrame *)p;
    if(IOSurfaceLock(frame.surface,writing?0:kIOSurfaceLockReadOnly,NULL)!=kIOReturnSuccess)return -1;
    *bytes=IOSurfaceGetBaseAddress(frame.surface);*stride=IOSurfaceGetBytesPerRow(frame.surface);*size=IOSurfaceGetAllocSize(frame.surface);
    if(!*bytes){IOSurfaceUnlock(frame.surface,writing?0:kIOSurfaceLockReadOnly,NULL);return -1;}return 0;
}
int spice_zig_graphics_frame_unlock(void *p,int writing) {if(!p)return -1;return IOSurfaceUnlock(((__bridge SZFrame *)p).surface,writing?0:kIOSurfaceLockReadOnly,NULL)==kIOReturnSuccess?0:-1;}
void *spice_zig_graphics_frame_texture(void *p){return p?(__bridge void *)((__bridge SZFrame *)p).texture:NULL;}
void *spice_zig_graphics_frame_surface(void *p){return p?(void *)((__bridge SZFrame *)p).surface:NULL;}
static int finish(SZGraphics *g,id<MTLCommandBuffer> command) {
    if(!command)return -1;[command commit];atomic_fetch_add(&g->submitted,1);[command waitUntilCompleted];
    return command.status==MTLCommandBufferStatusCompleted && !command.error?0:-1;
}
int spice_zig_graphics_copy(void *context,void *source,void *destination) {
    @autoreleasepool {
        if(!context || !source || !destination || source==destination)return -1;
        SZGraphics *g=(__bridge SZGraphics *)context;SZFrame *src=(__bridge SZFrame *)source,*dst=(__bridge SZFrame *)destination;
        if(src.texture.width!=dst.texture.width || src.texture.height!=dst.texture.height)return -1;
        id<MTLCommandBuffer> command=[g.queue commandBuffer];id<MTLBlitCommandEncoder> encoder=[command blitCommandEncoder];if(!encoder)return -1;
        [encoder copyFromTexture:src.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(src.texture.width,src.texture.height,1) toTexture:dst.texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];[encoder endEncoding];return finish(g,command);
    }
}
int spice_zig_graphics_compose_bgra(void *context,void *source,void *destination,const uint32_t rects[12],int flip) {
    @autoreleasepool {
        if(!context || !source || !destination || source==destination || !rects)return -1;
        SZGraphics *g=(__bridge SZGraphics *)context;SZFrame *src=(__bridge SZFrame *)source,*dst=(__bridge SZFrame *)destination;
        for(unsigned i=0;i<3;i++)if(!rects[i*4+2] || !rects[i*4+3])return -1;
        if((uint64_t)rects[0]+rects[2]>src.texture.width || (uint64_t)rects[1]+rects[3]>src.texture.height ||
           (uint64_t)rects[4]+rects[6]>dst.texture.width || (uint64_t)rects[5]+rects[7]>dst.texture.height ||
           (uint64_t)rects[8]+rects[10]>dst.texture.width || (uint64_t)rects[9]+rects[11]>dst.texture.height)return -1;
        vector_uint4 uniforms[8]={0};uniforms[0]=(vector_uint4){(uint32_t)src.texture.width,(uint32_t)src.texture.height,flip!=0,0};
        for(unsigned i=0;i<3;i++)uniforms[i+1]=(vector_uint4){rects[i*4],rects[i*4+1],rects[i*4+2],rects[i*4+3]};
        id<MTLCommandBuffer> command=[g.queue commandBuffer];id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];if(!encoder)return -1;
        [encoder setComputePipelineState:g.bgra];[encoder setTexture:src.texture atIndex:0];[encoder setTexture:dst.texture atIndex:2];[encoder setBytes:uniforms length:sizeof(uniforms) atIndex:0];
        NSUInteger x=g.bgra.threadExecutionWidth;NSUInteger y=MAX((NSUInteger)1,MIN((NSUInteger)8,g.bgra.maxTotalThreadsPerThreadgroup/x));
        [encoder dispatchThreads:MTLSizeMake(rects[10],rects[11],1) threadsPerThreadgroup:MTLSizeMake(x,y,1)];[encoder endEncoding];return finish(g,command);
    }
}
int spice_zig_graphics_lanczos(void *context,void *source,void *destination) {
    @autoreleasepool {
        if(!context || !source || !destination || source==destination)return -1;
        SZGraphics *g=(__bridge SZGraphics *)context;SZFrame *src=(__bridge SZFrame *)source,*dst=(__bridge SZFrame *)destination;
        MPSImageLanczosScale *scale=[[MPSImageLanczosScale alloc] initWithDevice:g.device];if(!scale)return -1;scale.edgeMode=MPSImageEdgeModeClamp;
        id<MTLCommandBuffer> command=[g.queue commandBuffer];if(!command)return -1;
        [scale encodeToCommandBuffer:command sourceTexture:src.texture destinationTexture:dst.texture];return finish(g,command);
    }
}

// Bind CoreVideo planes without materializing BGRA. Pixel buffer, texture views
// and destination stay owned until finish's GPU fence completes on every path.
int spice_zig_graphics_compose_video(void *context,void *pixel,void *destination,const uint32_t uniforms[32]) {
    @autoreleasepool {
        if(!context || !pixel || !destination || !uniforms)return -1;
        SZGraphics *g=(__bridge SZGraphics *)context;SZFrame *dst=(__bridge SZFrame *)destination;
        CVPixelBufferRef source=(CVPixelBufferRef)pixel;
        size_t width=CVPixelBufferGetWidth(source),height=CVPixelBufferGetHeight(source);
        if(width!=uniforms[0] || height!=uniforms[1] || !width || !height)return -1;
        if(!uniforms[6] || !uniforms[7] || !uniforms[10] || !uniforms[11] || !uniforms[14] || !uniforms[15])return -1;
        if((uint64_t)uniforms[4]+uniforms[6]>width || (uint64_t)uniforms[5]+uniforms[7]>height ||
           (uint64_t)uniforms[8]+uniforms[10]>dst.texture.width || (uint64_t)uniforms[9]+uniforms[11]>dst.texture.height ||
           (uint64_t)uniforms[12]+uniforms[14]>dst.texture.width || (uint64_t)uniforms[13]+uniforms[15]>dst.texture.height)return -1;
        OSType format=CVPixelBufferGetPixelFormatType(source);
        BOOL packed=format==kCVPixelFormatType_32BGRA;
        if(!packed && format!=kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && format!=kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)return -1;
        if(!packed && (width%2 || height%2 || CVPixelBufferGetPlaneCount(source)!=2 ||
           CVPixelBufferGetWidthOfPlane(source,0)<width || CVPixelBufferGetHeightOfPlane(source,0)<height ||
           CVPixelBufferGetWidthOfPlane(source,1)<width/2 || CVPixelBufferGetHeightOfPlane(source,1)<height/2))return -1;
        CVMetalTextureCacheRef cache=(__bridge CVMetalTextureCacheRef)g.textureCacheOwner;
        CVMetalTextureRef luma=NULL,chroma=NULL;
        CVPixelBufferRetain(source);
        CVReturn status=CVMetalTextureCacheCreateTextureFromImage(NULL,cache,source,NULL,packed?MTLPixelFormatBGRA8Unorm:MTLPixelFormatR8Unorm,width,height,0,&luma);
        int result=-1;
        if(status==kCVReturnSuccess && luma){
            if(!packed)status=CVMetalTextureCacheCreateTextureFromImage(NULL,cache,source,NULL,MTLPixelFormatRG8Unorm,width/2,height/2,1,&chroma);
            if(status==kCVReturnSuccess && (packed || chroma)){
                id<MTLTexture> y=CVMetalTextureGetTexture(luma),uv=chroma?CVMetalTextureGetTexture(chroma):nil;
                if(y && (packed || uv)){
                    id<MTLComputePipelineState> pipeline=packed?g.bgra:g.nv12;
                    id<MTLCommandBuffer> command=[g.queue commandBuffer];id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
                    if(encoder){
                        [encoder setComputePipelineState:pipeline];[encoder setTexture:y atIndex:0];if(uv)[encoder setTexture:uv atIndex:1];
                        [encoder setTexture:dst.texture atIndex:2];[encoder setBytes:uniforms length:128 atIndex:0];
                        NSUInteger x=pipeline.threadExecutionWidth,ySize=MAX((NSUInteger)1,MIN((NSUInteger)8,pipeline.maxTotalThreadsPerThreadgroup/x));
                        [encoder dispatchThreads:MTLSizeMake(uniforms[14],uniforms[15],1) threadsPerThreadgroup:MTLSizeMake(x,ySize,1)];[encoder endEncoding];result=finish(g,command);
                    }
                }
            }
        }
        if(chroma)CFRelease(chroma);if(luma)CFRelease(luma);CVPixelBufferRelease(source);return result;
    }
}

@interface SZPresenter : NSObject
@property(nonatomic,strong) SZGraphics *graphics;
@property(nonatomic,strong) id<MTLRenderPipelineState> pipeline;
@property(nonatomic,strong) id<MTLSamplerState> sampler;
@property(nonatomic,strong) MPSImageLanczosScale *scaler;
@end
@implementation SZPresenter
@end
void *spice_zig_presenter_create(void *context,const char *path) {
    @autoreleasepool {
        if(!context || !path)return NULL;
        SZPresenter *p=[SZPresenter new];p.graphics=(__bridge SZGraphics *)context;
        NSString *filename=[[NSString alloc] initWithUTF8String:path];if(!filename)return NULL;
        NSError *error=nil;
        id<MTLLibrary> library=[p.graphics.device newLibraryWithURL:[NSURL fileURLWithPath:filename] error:&error];if(!library)return NULL;
        MTLRenderPipelineDescriptor *descriptor=[MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction=[library newFunctionWithName:@"spice_present_vertex"];
        descriptor.fragmentFunction=[library newFunctionWithName:@"spice_present_fragment"];
        descriptor.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
        if(!descriptor.vertexFunction || !descriptor.fragmentFunction)return NULL;
        p.pipeline=[p.graphics.device newRenderPipelineStateWithDescriptor:descriptor error:&error];if(!p.pipeline)return NULL;
        MTLSamplerDescriptor *sampler=[MTLSamplerDescriptor new];sampler.minFilter=MTLSamplerMinMagFilterNearest;sampler.magFilter=MTLSamplerMinMagFilterNearest;
        sampler.mipFilter=MTLSamplerMipFilterNotMipmapped;sampler.sAddressMode=MTLSamplerAddressModeClampToEdge;sampler.tAddressMode=MTLSamplerAddressModeClampToEdge;
        p.sampler=[p.graphics.device newSamplerStateWithDescriptor:sampler];if(!p.sampler)return NULL;
        p.scaler=[[MPSImageLanczosScale alloc] initWithDevice:p.graphics.device];p.scaler.edgeMode=MPSImageEdgeModeClamp;
        if(!p.scaler)return NULL;return (__bridge_retained void *)p;
    }
}
void spice_zig_presenter_destroy(void *handle){if(handle){id object=CFBridgingRelease(handle);(void)object;}}
static uint64_t SZContinuousNanoseconds(void) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ (void)mach_timebase_info(&timebase); });
    return (uint64_t)((__uint128_t)mach_continuous_time()*timebase.numer/timebase.denom);
}
@interface SZPresentationObservation : NSObject
@property(nonatomic) SpiceZigNativePresentationObserver observer;
@end
@implementation SZPresentationObservation
- (void)dealloc { if(_observer.context)_observer.release(_observer.context); }
- (void)emit:(SpiceZigNativePresentationEvent)value {
    dispatch_async(dispatch_get_main_queue(), ^{ self.observer.event(self.observer.context,&value); });
}
@end
int spice_zig_presenter_submit(void *handle,void *source,void *destination,void *drawable,uint32_t width,uint32_t height,int lanczos,void (*completion)(void *,int),void *user) {
    return spice_zig_presenter_submit_observed(handle,source,destination,drawable,width,height,lanczos,completion,user,NULL,NULL);
}
int spice_zig_presenter_submit_observed(void *handle,void *source,void *destination,void *drawableHandle,uint32_t width,uint32_t height,int lanczos,void (*completion)(void *,int),void *user,const SpiceZigNativePresentationObserver *observer,uint64_t *commit_ns){
    @autoreleasepool {
        if(commit_ns)*commit_ns=0;
        if(observer && (![NSThread isMainThread] || !observer->context || !observer->retain || !observer->release || !observer->event))return -1;
        if(!handle || !source || !destination || !completion || !user || !width || !height || width>16384 || height>16384)return -1;
        SZPresenter *p=(__bridge SZPresenter *)handle;SZFrame *src=(__bridge SZFrame *)source;id<MTLTexture> dst=(__bridge id<MTLTexture>)destination;
        id<CAMetalDrawable> drawable=(__bridge id<CAMetalDrawable>)drawableHandle;
        if(dst==src.texture || dst.width!=width || dst.height!=height || dst.pixelFormat!=MTLPixelFormatBGRA8Unorm || src.texture.pixelFormat!=MTLPixelFormatBGRA8Unorm || dst.device!=p.graphics.device || src.texture.device!=p.graphics.device || (drawable && drawable.texture!=dst))return -1;
        if(lanczos ? !(dst.usage&MTLTextureUsageShaderWrite) : !(dst.usage&MTLTextureUsageRenderTarget))return -1;
        id<MTLCommandBuffer> command=[p.graphics.queue commandBuffer];if(!command)return -1;
        if(lanczos){[p.scaler encodeToCommandBuffer:command sourceTexture:src.texture destinationTexture:dst];}
        else {
            MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=dst;
            pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);
            id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];if(!encoder)return -1;
            [encoder setRenderPipelineState:p.pipeline];[encoder setFragmentTexture:src.texture atIndex:0];[encoder setFragmentSamplerState:p.sampler atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];[encoder endEncoding];
        }
        SZPresentationObservation *observation=nil;
        if(observer){
            observation=[SZPresentationObservation new];
            observer->retain(observer->context);observation.observer=*observer;
            if(drawable)[drawable addPresentedHandler:^(id<MTLDrawable> presented){
                double mediaTime=presented.presentedTime;
                double mediaNow=CACurrentMediaTime();
                uint64_t now=SZContinuousNanoseconds();
                [observation emit:(SpiceZigNativePresentationEvent){2,mediaTime>0?0:-1,now,mediaTime,mediaNow}];
            }];
        }
        [command addCompletedHandler:^(id<MTLCommandBuffer> done){
            // Explicit captures keep every borrowed Apple object alive through
            // the callback, independently of caller/context/view destruction.
            (void)p.graphics;(void)src.texture;(void)dst.width;(void)drawable.texture;
            int status=done.status==MTLCommandBufferStatusCompleted && !done.error?0:-1;
            uint64_t now=SZContinuousNanoseconds();
            if(observation)[observation emit:(SpiceZigNativePresentationEvent){1,status,now,0,0}];
            completion(user,status);
        }];
        if(drawable)[command presentDrawable:drawable];
        uint64_t committed=SZContinuousNanoseconds();
        [command commit];
        if(commit_ns)*commit_ns=committed;
        atomic_fetch_add(&p.graphics->submitted,1);return 0;
    }
}

void spice_zig_graphics_memory(void *graphics, uint64_t *recommended, uint64_t *allocated) {
    SZGraphics *g=(__bridge SZGraphics *)graphics;
    *recommended=g.device.recommendedMaxWorkingSetSize;
    *allocated=g.device.currentAllocatedSize;
}
