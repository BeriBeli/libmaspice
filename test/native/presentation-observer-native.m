// Actual CAMetalLayer drawable callbacks, separate from GPU completion.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#include "graphics_bridge.h"
#include "spice_zig_desktop.h"
_Static_assert(sizeof(SpiceZigPresentationObservation)==32,"observation ABI");
_Static_assert(sizeof(SpiceZigNativePresentationEvent)==sizeof(SpiceZigPresentationObservation),"native observation ABI");
_Static_assert(sizeof(SpiceZigNativePresentationObserver)==sizeof(SpiceZigPresentationObserver),"native observer ABI");
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
@interface ObserverTestView : MTKView
@property(nonatomic,copy) void (^render)(id<CAMetalDrawable>);
@end
@implementation ObserverTestView
- (void)drawRect:(NSRect)rect { (void)rect; if(self.render)self.render(self.currentDrawable); }
@end
typedef struct {
    _Atomic(unsigned) refs;
    _Atomic(unsigned) gpu;
    unsigned command,presented,dropped;
    uint64_t commit_ns;
    double media_time;
} State;
static void retainState(void *p){atomic_fetch_add(&((State *)p)->refs,1);}
static void releaseState(void *p){assert(atomic_fetch_sub(&((State *)p)->refs,1)>1);}
static void observe(void *p,const SpiceZigNativePresentationEvent *event){
    assert([NSThread isMainThread]);State *s=p;
    assert(s->commit_ns && event->continuous_ns>=s->commit_ns);
    if(event->stage==1){assert(!event->status);s->command++;assert(!event->media_time);}
    else {assert(event->stage==2);if(event->status==0){s->presented++;assert(event->media_time>0);assert(event->media_now>=event->media_time);s->media_time=event->media_time;}else {assert(event->status==-1 && event->media_time==0);s->dropped++;}}
}
static void completed(void *p,int status){assert(status==0);atomic_fetch_add(&((State *)p)->gpu,1);}
static void pump(void){
    NSEvent *event;while((event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES]))[NSApp sendEvent:event];
    [NSApp updateWindows];[CATransaction flush];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}
int main(int argc,char **argv){
    assert(argc==3);
    @autoreleasepool {
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
        NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(80,80,160,120) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed=NO;window.title=@"Spice Zig presentation validation";
        ObserverTestView *view=[[ObserverTestView alloc] initWithFrame:NSMakeRect(0,0,160,120) device:MTLCreateSystemDefaultDevice()];assert(view.device);
        view.paused=YES;view.enableSetNeedsDisplay=NO;view.framebufferOnly=NO;view.colorPixelFormat=MTLPixelFormatBGRA8Unorm;view.autoResizeDrawable=NO;view.drawableSize=CGSizeMake(160,120);
        window.contentView=view;[window makeKeyAndOrderFront:nil];
        [CATransaction flush];for(unsigned i=0;i<30;i++)pump();
        fprintf(stderr,"display asleep=%d online=%d\n",CGDisplayIsAsleep(CGMainDisplayID()),CGDisplayIsOnline(CGMainDisplayID()));
        id<MTLCommandQueue> probeQueue=[view.device newCommandQueue];
        __block unsigned probeDone=0;
        view.render=^(id<CAMetalDrawable> drawable){
            id<MTLCommandBuffer> buffer=[probeQueue commandBuffer];
            MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=drawable.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(1,0,0,1);
            id<MTLRenderCommandEncoder> encoder=[buffer renderCommandEncoderWithDescriptor:pass];[encoder endEncoding];
            [drawable addPresentedHandler:^(id<MTLDrawable> value){double time=value.presentedTime;dispatch_async(dispatch_get_main_queue(), ^{fprintf(stderr,"independent clear presented=%g\n",time);probeDone=1;});}];
            [buffer presentDrawable:drawable];[buffer commit];
        };
        [view draw];view.render=nil;
        NSDate *probeDeadline=[NSDate dateWithTimeIntervalSinceNow:5];while(!probeDone && probeDeadline.timeIntervalSinceNow>0)pump();
        unsigned shown=0,dropped=0;
        for(unsigned mode=0;mode<3;mode++){
            State state={.refs=1};bool displayAsleep=CGDisplayIsAsleep(CGMainDisplayID());
            @autoreleasepool {
                void *graphics=spice_zig_graphics_create(argv[1]);assert(graphics);
                void *source=spice_zig_graphics_frame_create(graphics,80,60);assert(source);
                uint8_t *pixels=NULL;size_t stride=0,size=0;
                assert(!spice_zig_graphics_frame_lock(source,1,&pixels,&stride,&size));
                for(unsigned y=0;y<60;y++)for(unsigned x=0;x<80;x++){uint8_t *p=pixels+y*stride+x*4;p[0]=30;p[1]=70;p[2]=140;p[3]=255;}
                assert(!spice_zig_graphics_frame_unlock(source,1));
                void *presenter=spice_zig_presenter_create(graphics,argv[2]);assert(presenter);
                State *sp=&state;
                void (^render)(id<CAMetalDrawable>)=^(id<CAMetalDrawable> drawable){
                    if(mode<2)assert(drawable);
                    MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:160 height:120 mipmapped:NO];
                    descriptor.usage=MTLTextureUsageShaderWrite|MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
                    id<MTLTexture> target=drawable?drawable.texture:[view.device newTextureWithDescriptor:descriptor];assert(target);
                    SpiceZigNativePresentationObserver observer={sp,retainState,releaseState,observe};
                    uint64_t invalid_commit=123;
                    assert(spice_zig_presenter_submit_observed(presenter,source,(__bridge void *)target,(__bridge void *)drawable,0,120,0,completed,sp,&observer,&invalid_commit)==-1);
                    assert(!invalid_commit && atomic_load(&sp->refs)==1 && !atomic_load(&sp->gpu));
                    assert(!spice_zig_presenter_submit_observed(presenter,source,(__bridge void *)target,(__bridge void *)drawable,160,120,mode==1,completed,sp,&observer,&sp->commit_ns));
                    assert(sp->commit_ns && !sp->command && !sp->presented);
                };
                if(mode<2){view.render=render;[view draw];view.render=nil;}else render(nil);
                // Native callbacks retain their own Apple objects and observation.
                spice_zig_presenter_destroy(presenter);spice_zig_graphics_frame_destroy(source);spice_zig_graphics_destroy(graphics);

                NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:10];
                while((!atomic_load(&state.gpu)||!state.command||(mode<2&&!state.presented&&!state.dropped)) && deadline.timeIntervalSinceNow>0)pump();
                assert(atomic_load(&state.gpu)==1 && state.command==1 && state.presented+state.dropped==(mode<2?1:0));
                if(mode<2 && !displayAsleep && !CGDisplayIsAsleep(CGMainDisplayID()))assert(state.presented==1);
                shown+=state.presented;dropped+=state.dropped;
            }
            NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
            while(atomic_load(&state.refs)!=1 && deadline.timeIntervalSinceNow>0)pump();
            assert(atomic_load(&state.refs)==1);
        }
        [window orderOut:nil];[window close];
        printf("native observations: actual_presentations=%u dropped_callbacks=%u; GPU completion, offscreen command-only, failure cleanup and independent ownership passed\n",shown,dropped);
        if(!shown)puts("Actual screen presentation timestamp gate PENDING: display asleep; no success inferred from GPU completion.");
    }
    return 0;
}
