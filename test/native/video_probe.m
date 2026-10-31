#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
// Independent fixture construction. CoreVideo owns all plane storage.
void *video_probe_frame(uint32_t width,uint32_t height,int full,int matrix,const uint8_t *y,const uint8_t *uv) {
    if(!width || !height || width>16384 || height>16384 || !y || !uv)return NULL;
    CVPixelBufferRef p=NULL;
    NSDictionary *attributes=@{(id)kCVPixelBufferMetalCompatibilityKey:@YES,(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    if(CVPixelBufferCreate(NULL,width,height,full?kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,(__bridge CFDictionaryRef)attributes,&p)!=kCVReturnSuccess)return NULL;
    if(CVPixelBufferLockBaseAddress(p,0)!=kCVReturnSuccess){CFRelease(p);return NULL;}
    uint8_t *yb=CVPixelBufferGetBaseAddressOfPlane(p,0),*cb=CVPixelBufferGetBaseAddressOfPlane(p,1);
    size_t ys=CVPixelBufferGetBytesPerRowOfPlane(p,0),cs=CVPixelBufferGetBytesPerRowOfPlane(p,1),cw=((width+1)/2)*2;
    for(size_t row=0;row<height;row++)memcpy(yb+row*ys,y+row*width,width);
    for(size_t row=0;row<(height+1)/2;row++)memcpy(cb+row*cs,uv+row*cw,cw);
    CVPixelBufferUnlockBaseAddress(p,0);
    CFStringRef name=matrix==601?kCVImageBufferYCbCrMatrix_ITU_R_601_4:matrix==709?kCVImageBufferYCbCrMatrix_ITU_R_709_2:matrix==2020?kCVImageBufferYCbCrMatrix_ITU_R_2020:NULL;
    if(name)CVBufferSetAttachment(p,kCVImageBufferYCbCrMatrixKey,name,kCVAttachmentMode_ShouldPropagate);
    return (void *)p;
}
