// Test-only native queue gate. Uses actual MTLSharedEvent ordering to hold a
// submitted command on the GPU until the cancellation test releases it.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
@interface SZGraphics : NSObject
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) id<MTLCommandQueue> queue;
@end
void *graphics_test_gate(void *context) {
    SZGraphics *g=(__bridge SZGraphics *)context;
    id<MTLSharedEvent> event=[g.device newSharedEvent];
    id<MTLCommandBuffer> command=[g.queue commandBuffer];
    if(!event || !command)return NULL;
    [command encodeWaitForEvent:event value:1];[command commit];
    return (__bridge_retained void *)event;
}
void graphics_test_release_gate(void *handle) {
    id<MTLSharedEvent> event=CFBridgingRelease(handle);event.signaledValue=1;
}
