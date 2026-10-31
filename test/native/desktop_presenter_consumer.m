// Host-facing Metal objects with only the public Zig consumer API.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "spice_zig_desktop.h"
#include <assert.h>
#include <stdlib.h>
struct ConsumerPresenter {SpiceZigDesktopPresenter *value;unsigned completions;};
static void completed(void *user,const SpiceZigPresentationCompletion *result){
    struct ConsumerPresenter *self=user;assert(result->succeeded && result->current && result->surface_id==7);self->completions++;
}
void *consumer_presenter_create(SpiceZigDesktop *desktop,const char *library){
    struct ConsumerPresenter *self=calloc(1,sizeof(*self));assert(self);
    assert(!spice_zig_desktop_presenter_create(desktop,library,completed,self,&self->value));return self;
}
void consumer_presenter_render(void *handle,const SpiceZigFrame *frame,uint8_t output[256]){
    @autoreleasepool {
        struct ConsumerPresenter *self=handle;
        id<MTLTexture> source=(__bridge id<MTLTexture>)spice_zig_frame_texture(frame);assert(source);
        MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:8 height:8 mipmapped:NO];
        descriptor.storageMode=MTLStorageModeShared;descriptor.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderWrite|MTLTextureUsageShaderRead;
        id<MTLTexture> target=[source.device newTextureWithDescriptor:descriptor];assert(target);
        assert(spice_zig_desktop_presenter_submit(self->value,frame,(__bridge void *)target,8,8,NULL)==0);
        spice_zig_desktop_presenter_wait_idle(self->value);assert(self->completions==1);
        [target getBytes:output bytesPerRow:32 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];
        spice_zig_desktop_presenter_destroy(self->value);free(self);
    }
}
