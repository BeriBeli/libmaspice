#import "video_bridge.h"
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include <stdatomic.h>
// Construction and CoreMedia hold separate owner references. A failing block
// creation can invoke FreeBlock; the claim prevents double release on failure.
typedef struct { _Atomic(unsigned) refs; _Atomic(bool) claimed; void *context; void (*release)(void *); } SZSampleOwner;
static void ownerDrop(SZSampleOwner *o) { if(atomic_fetch_sub(&o->refs,1)==1){o->release(o->context);free(o);} }
static void ownerClaim(SZSampleOwner *o) { if(!atomic_exchange(&o->claimed,true))ownerDrop(o); }
static void freeBlock(void *refcon, void *bytes, size_t size) {(void)bytes;(void)size;ownerClaim(refcon);}
int32_t spice_zig_video_format(int hevc,const uint8_t *const *sets,const size_t *sizes,size_t count,void **out) {
    if(!out)return paramErr;*out=NULL;CMVideoFormatDescriptionRef format=NULL;
    OSStatus s=hevc?CMVideoFormatDescriptionCreateFromHEVCParameterSets(NULL,count,sets,sizes,4,NULL,&format):CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL,count,sets,sizes,4,&format);
    if(s){if(format)CFRelease(format);return s;}*out=(void *)format;return 0;
}
void spice_zig_video_format_release(void *p){if(p)CFRelease(p);}
void spice_zig_video_format_size(void *p,int32_t *w,int32_t *h){CMVideoDimensions d=CMVideoFormatDescriptionGetDimensions(p);*w=d.width;*h=d.height;}
int32_t spice_zig_video_session(void *format,void **out) {
    @autoreleasepool {
        if(!out)return paramErr;*out=NULL;VTDecompressionSessionRef session=NULL;
        OSStatus s=VTDecompressionSessionCreate(NULL,format,(__bridge CFDictionaryRef)@{(id)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder:@YES},(__bridge CFDictionaryRef)@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),(id)kCVPixelBufferMetalCompatibilityKey:@YES,(id)kCVPixelBufferIOSurfacePropertiesKey:@{}},NULL,&session);
        if(s){if(session){VTDecompressionSessionInvalidate(session);CFRelease(session);}return s;}*out=(void *)session;return 0;
    }
}
int32_t spice_zig_video_realtime(void *p){return VTSessionSetProperty(p,kVTDecompressionPropertyKey_RealTime,kCFBooleanTrue);}
int32_t spice_zig_video_hardware(void *p,int *hardware){
    if(!hardware)return paramErr;*hardware=0;CFTypeRef value=NULL;
    OSStatus s=VTSessionCopyProperty(p,kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,NULL,&value);
    if(!s && value && CFGetTypeID(value)==CFBooleanGetTypeID())*hardware=CFBooleanGetValue(value)?1:0;
    else if(!s)s=paramErr;
    if(value)CFRelease(value);return s;
}
void spice_zig_video_session_release(void *p){if(p){VTDecompressionSessionInvalidate(p);CFRelease(p);}}
int32_t spice_zig_video_decode(void *session,void *format,const uint8_t *bytes,size_t size,uint32_t time,void *owner,void (*release)(void *),void **pixel){
    @autoreleasepool {
    if(!release)return paramErr;
    if(!session || !format || !bytes || !size || !pixel){release(owner);return paramErr;}
    *pixel=NULL;SZSampleOwner *o=calloc(1,sizeof(*o));if(!o){release(owner);return memFullErr;}
    atomic_init(&o->refs,2);atomic_init(&o->claimed,false);o->context=owner;o->release=release;
    CMBlockBufferCustomBlockSource source={.version=kCMBlockBufferCustomBlockSourceVersion,.FreeBlock=freeBlock,.refCon=o};
    CMBlockBufferRef block=NULL;
    OSStatus s=CMBlockBufferCreateWithMemoryBlock(NULL,(void *)bytes,size,NULL,&source,0,size,0,&block);
    if(s || !block){if(block)CFRelease(block);ownerClaim(o);ownerDrop(o);return s?s:memFullErr;}
    ownerDrop(o); // CoreMedia now owns the sole remaining reference.
    CMSampleTimingInfo timing={.duration=kCMTimeInvalid,.presentationTimeStamp=CMTimeMake(time,1000),.decodeTimeStamp=kCMTimeInvalid};
    CMSampleBufferRef sample=NULL;s=CMSampleBufferCreateReady(NULL,block,format,1,1,&timing,1,&size,&sample);CFRelease(block);
    if(s || !sample){if(sample)CFRelease(sample);return s?s:memFullErr;}
    __block CVPixelBufferRef output=NULL;__block OSStatus result=0;__block bool called=false;
    VTDecodeInfoFlags flags=0;
    // Neither asynchronous nor temporal-processing flag: SDK guarantees callback
    // before return. Retain the pixel, never a borrowed callback image.
    s=VTDecompressionSessionDecodeFrameWithOutputHandler(session,sample,0,&flags,^(OSStatus status,VTDecodeInfoFlags info,CVImageBufferRef image,CMTime pts,CMTime duration){
        (void)pts;(void)duration;called=true;result=status;
        if(!status && !(info&kVTDecodeInfo_FrameDropped) && image)output=CVPixelBufferRetain(image);
    });
    CFRelease(sample);
    if(s || result || !called){if(output)CVPixelBufferRelease(output);return s?s:(result?result:kVTVideoDecoderMalfunctionErr);}
    *pixel=(void *)output;return 0;
    }
}
void spice_zig_video_frame_release(void *p){if(p)CVPixelBufferRelease(p);}
void spice_zig_video_frame_retain(void *p){if(p)CVPixelBufferRetain(p);}
int spice_zig_video_metadata(void *p,uint32_t m[5]){
    if(!p || !m)return -1;size_t w=CVPixelBufferGetWidth(p),h=CVPixelBufferGetHeight(p);if(w>UINT32_MAX || h>UINT32_MAX)return -1;
    OSType f=CVPixelBufferGetPixelFormatType(p);m[0]=(uint32_t)w;m[1]=(uint32_t)h;m[2]=0;m[3]=0;m[4]=0;
    if(f==kCVPixelFormatType_32BGRA){m[2]=1;m[4]=1;}
    if(f==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || f==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange){m[2]=2;m[4]=f==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange?2:1;}
    CFTypeRef matrix=CVBufferCopyAttachment(p,kCVImageBufferYCbCrMatrixKey,NULL);
    if(matrix){if(CFEqual(matrix,kCVImageBufferYCbCrMatrix_ITU_R_601_4))m[3]=601;else if(CFEqual(matrix,kCVImageBufferYCbCrMatrix_ITU_R_709_2))m[3]=709;CFRelease(matrix);}return 0;
}
int spice_zig_video_lock(void *p){return CVPixelBufferLockBaseAddress(p,kCVPixelBufferLock_ReadOnly);}
int spice_zig_video_unlock(void *p){return CVPixelBufferUnlockBaseAddress(p,kCVPixelBufferLock_ReadOnly);}
int spice_zig_video_plane(void *p,size_t plane,const uint8_t **base,size_t *w,size_t *h,size_t *stride){
    if(!p || !base || !w || !h || !stride)return -1;
    if(!CVPixelBufferIsPlanar(p)){if(plane)return -1;*base=CVPixelBufferGetBaseAddress(p);*w=CVPixelBufferGetWidth(p);*h=CVPixelBufferGetHeight(p);*stride=CVPixelBufferGetBytesPerRow(p);}
    else {if(plane>=CVPixelBufferGetPlaneCount(p))return -1;*base=CVPixelBufferGetBaseAddressOfPlane(p,plane);*w=CVPixelBufferGetWidthOfPlane(p,plane);*h=CVPixelBufferGetHeightOfPlane(p,plane);*stride=CVPixelBufferGetBytesPerRowOfPlane(p,plane);}return *base?0:-1;
}
