#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include "spice_zig_host_view.h"
#include <stdatomic.h>
#include <assert.h>
#include <stdio.h>
void *host_fixture_create(const char *);
void host_fixture_destroy(void *);
int host_fixture_publish(void *,int);
uint64_t host_fixture_metric(void *,uint32_t);
// A sleeping screen reports complete occlusion, so normal production demand
// MUST remain off. After checking that, inject visibility at the NSWindow input
// boundary to exercise rendering/lifetimes without waking/unlocking the screen.
@interface HostTestWindow : NSWindow
@property(nonatomic) BOOL testVisible;
@end
@implementation HostTestWindow
- (NSWindowOcclusionState)occlusionState {
    return _testVisible?NSWindowOcclusionStateVisible:[super occlusionState];
}
@end
typedef struct {_Atomic(unsigned) refs;unsigned count;uint8_t kinds[32];int32_t values[32];} State;
static void retainState(void *p){atomic_fetch_add(&((State *)p)->refs,1);}
static void releaseState(void *p){assert(atomic_fetch_sub(&((State *)p)->refs,1)>1);}
static void input(void *p,uint8_t kind,int32_t x,int32_t y,uint8_t display){
    (void)y;(void)display;State *s=p;assert(NSThread.isMainThread && s->count<32);
    s->kinds[s->count]=kind;s->values[s->count]=x;s->count++;
}
static void pump(void){
    NSEvent *e;while((e=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:YES]))[NSApp sendEvent:e];
    [NSApp updateWindows];[CATransaction flush];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}
static NSEvent *key(NSWindow *w,NSEventType type,unsigned short code,NSString *chars){
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:0 timestamp:1 windowNumber:w.windowNumber context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:code];
}
// Independent Cocoa reference for the existing Swift CPU draw contract:
// NSImage.draw(operation: .copy, respectFlipped: true, interpolation: .none).
@interface HostCPUReference : NSView
@end
@implementation HostCPUReference
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
    [NSColor.blackColor setFill];NSRectFill(dirty);
    NSMutableData *data=[NSMutableData dataWithLength:80*40*4];uint8_t *p=data.mutableBytes;
    for(unsigned y=0;y<40;y++)for(unsigned x=0;x<80;x++){
        size_t i=(y*80+x)*4;p[i]=y<20?0:255;p[i+1]=0;p[i+2]=y<20?255:0;p[i+3]=255;
    }
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGImageRef image=CGImageCreate(80,40,8,32,320,space,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst,provider,NULL,false,kCGRenderingIntentDefault);
    NSGraphicsContext.currentContext.imageInterpolation=NSImageInterpolationNone;
    NSImage *native=[[NSImage alloc] initWithCGImage:image size:NSMakeSize(160,80)];
    [native drawInRect:NSMakeRect(0,40,160,80) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation:@(NSImageInterpolationNone)}];
    CGImageRelease(image);CGColorSpaceRelease(space);CGDataProviderRelease(provider);
}
@end
static void checkCPU(NSView *view){
    NSBitmapImageRep *bitmap=[view bitmapImageRepForCachingDisplayInRect:view.bounds];assert(bitmap);
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    // View 160x160, image 80x40 aspect-fit => 160x80 centered, upper red/lower blue.
    HostCPUReference *reference=[[HostCPUReference alloc] initWithFrame:view.bounds];reference.wantsLayer=YES;
    [view addSubview:reference];
    NSBitmapImageRep *expected=[reference bitmapImageRepForCachingDisplayInRect:reference.bounds];assert(expected);
    [reference cacheDisplayInRect:reference.bounds toBitmapImageRep:expected];
    assert(bitmap.pixelsWide==expected.pixelsWide && bitmap.pixelsHigh==expected.pixelsHigh);
    assert(bitmap.bitsPerPixel==expected.bitsPerPixel && bitmap.bitsPerSample==expected.bitsPerSample);
    size_t row=(size_t)bitmap.pixelsWide*bitmap.bitsPerPixel/8;
    for(NSInteger y=0;y<bitmap.pixelsHigh;y++)assert(!memcmp(bitmap.bitmapData+y*bitmap.bytesPerRow,expected.bitmapData+y*expected.bytesPerRow,row));
    [reference removeFromSuperview];
    const char *capture=getenv("SPICE_ZIG_HOST_CAPTURE");if(capture)[[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[NSString stringWithUTF8String:capture] atomically:YES];
    puts("CPU bitmap matches independent Cocoa reference exactly (including display color management)");
}
int main(int argc,char **argv){
    assert(argc==3);
    @autoreleasepool {
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];[NSApp finishLaunching];
        for(unsigned mode=0;mode<2;mode++){
            State state={.refs=1};SpiceZigHostInput callbacks={&state,retainState,releaseState,input};
            __weak NSView *weakView=nil;
            @autoreleasepool {
                void *fixture=host_fixture_create(mode?argv[1]:NULL);assert(fixture);
                void *owned=spice_zig_host_view_create(fixture,0,0,argv[2],&callbacks);assert(owned && atomic_load(&state.refs)==2);
                NSView *view=(__bridge NSView *)owned;weakView=view;
                HostTestWindow *window=[[HostTestWindow alloc] initWithContentRect:NSMakeRect(80,80,160,160) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
                window.title=@"Spice Zig host view validation";window.releasedWhenClosed=NO;window.contentView=view;
                [window makeKeyAndOrderFront:nil];[window makeFirstResponder:view];
                for(unsigned i=0;i<20;i++)pump();
                BOOL visible=(window.occlusionState&NSWindowOcclusionStateVisible)!=0;
                assert(host_fixture_metric(fixture,6)==(visible?1:0));
                if(!visible){
                    assert(CGDisplayIsAsleep(CGMainDisplayID()));
                    window.testVisible=YES;
                    [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidChangeOcclusionStateNotification object:window];
                    fprintf(stderr,"display asleep: native occlusion correctly disabled demand; injecting visible window state for host rendering/lifecycle checks\n");
                }
                assert(host_fixture_metric(fixture,6)==1);
                assert(!host_fixture_publish(fixture,mode));
                // Visibility transitions exercise authoritative resumption even
                // when a sleeping display provides no physical refresh ticks.
                [view setHidden:YES];assert(host_fixture_metric(fixture,6)==0);
                [view setHidden:NO];
                NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:8];
                while(host_fixture_metric(fixture,mode?4:3)==0 && deadline.timeIntervalSinceNow>0)pump();
                assert(host_fixture_metric(fixture,mode?4:3)>0);
                assert(!spice_zig_host_view_last_error(owned));
                if(mode){assert(host_fixture_metric(fixture,0)>0);assert(!host_fixture_metric(fixture,2));}
                else checkCPU(view);
                assert([window makeFirstResponder:view]);
                [view keyDown:key(window,NSEventTypeKeyDown,0,@"a")];
                [view keyUp:key(window,NSEventTypeKeyUp,0,@"a")];
                [view keyDown:key(window,NSEventTypeKeyDown,65,@".")];
                [view keyUp:key(window,NSEventTypeKeyUp,65,@".")];
                assert(state.count==4 && state.kinds[0]==0 && state.values[0]==0x1e && state.kinds[1]==1 && state.values[2]==0x34);
                [view keyDown:key(window,NSEventTypeKeyDown,0,@"a")];
                [window makeFirstResponder:nil];
                assert(state.count==6 && state.kinds[5]==1 && state.values[5]==0x1e);
                // Original Source/graphics owner can disappear before the view.
                // Queue another real publication, then dismantle immediately.
                assert(!host_fixture_publish(fixture,mode));
                host_fixture_destroy(fixture);
                if(!mode){spice_zig_host_view_close(owned);spice_zig_host_view_close(owned);}
                [view removeFromSuperview];[window orderOut:nil];[window close];
                spice_zig_host_view_release(owned);view=nil;window=nil;
            }
            NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:8];
            while((atomic_load(&state.refs)!=1 || weakView) && deadline.timeIntervalSinceNow>0)pump();
            assert(!weakView && atomic_load(&state.refs)==1);
        }
        printf("native host: CPU orientation/letterbox pixels, GPU commit/completion, NSEvent keys/focus, visibility, queued teardown and ownership passed; display_asleep=%d\n",CGDisplayIsAsleep(CGMainDisplayID()));
    }
    return 0;
}
