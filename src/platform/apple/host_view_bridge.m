// Thin AppKit/MetalKit edge: scalar events, drawable acquisition, CoreGraphics
// drawing and cursor system calls. Scheduling/recovery/selection live in Zig.
#import <AppKit/AppKit.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#include "host_view_bridge.h"
#include "spice_zig_host_view.h"
@class SZHostView;
@interface SZHostBox : NSObject
@property(nonatomic,weak) SZHostView *view;
@property(nonatomic) SpiceZigHostInput callbacks;
@property(nonatomic,copy) NSString *error;
@end
@implementation SZHostBox
- (void)dealloc { if(_callbacks.release)_callbacks.release(_callbacks.context); }
@end
@interface SZHostMetalView : MTKView
@end
@implementation SZHostMetalView
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
@end
@interface SZHostOverlay : NSView
@end
@implementation SZHostOverlay
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
@end
@interface SZHostTick : NSObject
@property(nonatomic,weak) SZHostView *view;
- (void)tick:(CADisplayLink *)link;
@end
@interface SZHostView : NSView <MTKViewDelegate>
@property(nonatomic) void *controller;
@property(nonatomic,strong) SZHostBox *box;
@property(nonatomic,strong) SZHostMetalView *metal;
@property(nonatomic,strong) SZHostOverlay *overlay;
@property(nonatomic,strong) CALayer *cursorLayer;
@property(nonatomic,strong) CADisplayLink *displayLink;
@property(nonatomic,strong) SZHostTick *tickTarget;
@property(nonatomic,strong) NSCursor *desktopCursor;
@property(nonatomic,strong) NSTrackingArea *desktopTracking;
@property(nonatomic,strong) NSData *cursorBytes;
@property(nonatomic,strong) id cursorImageOwner;
@property(nonatomic) uint16_t cursorWidth,cursorHeight;
@property(nonatomic) void *pendingController;
@property(nonatomic) int drawResult,contentKind;
- (void)refreshDemand;
- (void)close;
@end
@implementation SZHostTick
- (void)tick:(CADisplayLink *)link { (void)link; SZHostView *view=_view; if(view.controller)spice_zig_host_tick(view.controller); }
@end
static SZHostView *SZView(void *p) { return ((__bridge SZHostBox *)p).view; }
static SZHostRect SZRect(NSRect r) { return (SZHostRect){r.origin.x,r.origin.y,r.size.width,r.size.height}; }
static NSRect NSHostRect(SZHostRect r) { return NSMakeRect(r.x,r.y,r.width,r.height); }
static CGImageRef SZImage(const uint8_t *bytes,size_t count,uint32_t width,uint32_t height,int alpha) {
    if(!bytes || !width || !height || width>16384 || height>16384 || count!=(size_t)width*height*4)return NULL;
    CGDataProviderRef provider=CGDataProviderCreateWithData(NULL,bytes,count,NULL);
    if(!provider)return NULL;
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGImageRef image=space?CGImageCreate(width,height,8,32,(size_t)width*4,space,
        kCGBitmapByteOrder32Little|(alpha?kCGImageAlphaPremultipliedFirst:kCGImageAlphaNoneSkipFirst),provider,NULL,false,kCGRenderingIntentDefault):NULL;
    if(space)CGColorSpaceRelease(space);CGDataProviderRelease(provider);return image;
}
@implementation SZHostView
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (instancetype)initWithFrame:(NSRect)rect {
    self=[super initWithFrame:rect];if(!self)return nil;
    self.wantsLayer=YES;self.layer.masksToBounds=YES;
    _desktopCursor=NSCursor.arrowCursor;
    _overlay=[[SZHostOverlay alloc] initWithFrame:self.bounds];_overlay.wantsLayer=YES;
    _overlay.layer.masksToBounds=YES;
    _cursorLayer=[CALayer layer];_cursorLayer.hidden=YES;
    _cursorLayer.magnificationFilter=kCAFilterNearest;_cursorLayer.minificationFilter=kCAFilterNearest;
    [_overlay.layer addSublayer:_cursorLayer];[self addSubview:_overlay];
    _tickTarget=[SZHostTick new];_tickTarget.view=self;
    return self;
}
- (void)close {
    void *c=_controller;_controller=NULL;
    if(c){spice_zig_host_close(c);spice_zig_host_release(c);}
    [_displayLink invalidate];_displayLink=nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _metal.delegate=nil;_metal.hidden=YES;
}
- (void)dealloc {
    void *c=_controller;_controller=NULL;
    if(c){spice_zig_host_close(c);spice_zig_host_release(c);}
    [_displayLink invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)viewWillMoveToWindow:(NSWindow *)window {
    if(self.window!=window){
        if(_controller){spice_zig_host_focus_lost(_controller);spice_zig_host_configure(_controller,0,SZRect(self.bounds),self.window?self.window.backingScaleFactor:1);}
        [_displayLink invalidate];_displayLink=nil;
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
    [super viewWillMoveToWindow:window];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    NSWindow *window=self.window;
    if(window){
        window.acceptsMouseMovedEvents=YES;
        for(NSString *name in @[NSWindowDidResignKeyNotification,NSWindowWillCloseNotification])
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(focusLost:) name:name object:window];
        for(NSString *name in @[NSWindowDidChangeOcclusionStateNotification,NSWindowDidMiniaturizeNotification,NSWindowDidDeminiaturizeNotification])
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowChanged:) name:name object:window];
    }
    [self refreshDemand];
}
- (void)focusLost:(NSNotification *)note {
    if(_controller)spice_zig_host_focus_lost(_controller);
    if([note.name isEqualToString:NSWindowWillCloseNotification] && _controller)
        spice_zig_host_configure(_controller,0,SZRect(self.bounds),self.window.backingScaleFactor);
}
- (void)windowChanged:(NSNotification *)note { (void)note; [self refreshDemand]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self refreshDemand]; }
- (void)viewDidHide { [super viewDidHide]; [self refreshDemand]; }
- (void)viewDidUnhide { [super viewDidUnhide]; [self refreshDemand]; }
- (void)setHidden:(BOOL)hidden { [super setHidden:hidden]; [self refreshDemand]; }
- (void)layout { [super layout]; _overlay.frame=self.bounds; [self refreshDemand]; }
- (void)refreshDemand {
    if(!_controller)return;
    NSWindow *w=self.window;NSRect visible=self.visibleRect;
    BOOL active=w && !w.miniaturized && (w.occlusionState&NSWindowOcclusionStateVisible) &&
        !self.hiddenOrHasHiddenAncestor && visible.size.width>0 && visible.size.height>0;
    spice_zig_host_configure(_controller,active,SZRect(self.bounds),w?w.backingScaleFactor:1);
}
- (void)drawRect:(NSRect)dirty {
    [NSColor.blackColor setFill];NSRectFill(dirty);
    if(_controller && _contentKind==1)spice_zig_host_cpu_draw(_controller,NSGraphicsContext.currentContext.CGContext);
}
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size { (void)view;(void)size; }
- (void)drawInMTKView:(MTKView *)view {
    if(!_pendingController)return;
    id<CAMetalDrawable> drawable=view.currentDrawable;
    id<MTLTexture> texture=drawable.texture;
    _drawResult=spice_zig_host_submit(_pendingController,(__bridge void *)texture,(__bridge void *)drawable,
        texture?(uint32_t)texture.width:0,texture?(uint32_t)texture.height:0);
}
- (void)updateTrackingAreas {
    if(_desktopTracking)[self removeTrackingArea:_desktopTracking];
    _desktopTracking=[[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingActiveInKeyWindow|NSTrackingMouseEnteredAndExited|NSTrackingMouseMoved owner:self userInfo:nil];
    [self addTrackingArea:_desktopTracking];[super updateTrackingAreas];
}
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:_desktopCursor?:NSCursor.arrowCursor]; }
- (BOOL)resignFirstResponder { if(_controller)spice_zig_host_focus_lost(_controller);return [super resignFirstResponder]; }
- (void)keyDown:(NSEvent *)event {
    if(!_controller || !spice_zig_host_key(_controller,1,event.keyCode,event.modifierFlags,[event.charactersIgnoringModifiers isEqualToString:@"."]))[super keyDown:event];
}
- (void)keyUp:(NSEvent *)event {
    if(!_controller || !spice_zig_host_key(_controller,0,event.keyCode,event.modifierFlags,[event.charactersIgnoringModifiers isEqualToString:@"."]))[super keyUp:event];
}
- (void)flagsChanged:(NSEvent *)event { if(_controller)spice_zig_host_flags(_controller,event.keyCode,event.modifierFlags); }
- (void)button:(NSEvent *)event down:(BOOL)down {
    if(down)[self.window makeFirstResponder:self];
    if(_controller)spice_zig_host_button(_controller,down,event.buttonNumber,self.window.keyWindow);
}
- (void)mouseDown:(NSEvent *)event { [self button:event down:YES]; }
- (void)mouseUp:(NSEvent *)event { [self button:event down:NO]; }
- (void)rightMouseDown:(NSEvent *)event { [self button:event down:YES]; }
- (void)rightMouseUp:(NSEvent *)event { [self button:event down:NO]; }
- (void)otherMouseDown:(NSEvent *)event { [self button:event down:YES]; }
- (void)otherMouseUp:(NSEvent *)event { [self button:event down:NO]; }
- (void)mouseMoved:(NSEvent *)event {
    NSPoint point=[self convertPoint:event.locationInWindow fromView:nil];
    if(_controller)spice_zig_host_motion(_controller,(SZHostPoint){point.x,point.y},event.deltaX,event.deltaY);
}
- (void)mouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)rightMouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)otherMouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)scrollWheel:(NSEvent *)event { if(_controller)spice_zig_host_scroll(_controller,event.scrollingDeltaY); }
@end
void sz_host_box_destroy(void *p) { if(p){id owner=CFBridgingRelease(p);(void)owner;} }
void sz_host_schedule(void *p,void *controller) {
    (void)p;
    dispatch_async(dispatch_get_main_queue(),^{spice_zig_host_ready(controller);spice_zig_host_release(controller);});
}
void sz_host_ticking(void *p,int active) {
    SZHostView *v=SZView(p);if(!v)return;
    if(!active){v.displayLink.paused=YES;return;}
    if(!v.displayLink && v.window){v.displayLink=[v displayLinkWithTarget:v.tickTarget selector:@selector(tick:)];[v.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];}
    v.displayLink.paused=NO;
}
void sz_host_layout(void *p,SZHostRect rect,double width,double height) {
    SZHostView *v=SZView(p);if(!v)return;
    NSRect frame=NSHostRect(rect);if(!NSEqualRects(v.metal.frame,frame))v.metal.frame=frame;
    CGSize size=CGSizeMake(width,height);if(!CGSizeEqualToSize(v.metal.drawableSize,size))v.metal.drawableSize=size;
}
int sz_host_draw(void *p,void *controller) {
    SZHostView *v=SZView(p);if(!v || !v.metal)return 2;
    BOOL wasHidden=v.metal.hidden;
    v.pendingController=controller;v.drawResult=1;v.metal.hidden=NO;
    [v.metal draw];v.pendingController=NULL;if(v.drawResult!=0)v.metal.hidden=wasHidden;return v.drawResult;
}
void sz_host_content(void *p,int kind) {
    SZHostView *v=SZView(p);if(!v)return;
    v.contentKind=kind;v.metal.hidden=kind!=2;v.needsDisplay=YES;
    if(kind==0){v.cursorLayer.hidden=YES;v.cursorLayer.contents=nil;v.cursorBytes=nil;v.cursorImageOwner=nil;}
}
void sz_host_cursor(void *p,int kind,const uint8_t *bytes,size_t count,uint16_t width,uint16_t height,SZHostPoint hotspot,SZHostPoint size,const SZHostRect *overlay) {
    SZHostView *v=SZView(p);if(!v)return;
    BOOL valid=count==(size_t)width*height*4 && width && height && bytes;
    if(valid && (v.cursorWidth!=width || v.cursorHeight!=height || v.cursorBytes.length!=count || memcmp(v.cursorBytes.bytes,bytes,count)!=0)){
        v.cursorBytes=[NSData dataWithBytes:bytes length:count];v.cursorWidth=width;v.cursorHeight=height;
        CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)v.cursorBytes);
        CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
        CGImageRef image=provider&&space?CGImageCreate(width,height,8,32,(size_t)width*4,space,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst,provider,NULL,false,kCGRenderingIntentDefault):NULL;
        v.cursorImageOwner=CFBridgingRelease(image);if(provider)CGDataProviderRelease(provider);if(space)CGColorSpaceRelease(space);
    }
    CGImageRef image=valid?(__bridge CGImageRef)v.cursorImageOwner:NULL;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    v.cursorLayer.hidden=!(overlay && image);v.cursorLayer.contents=overlay?v.cursorImageOwner:nil;
    if(overlay){v.cursorLayer.frame=NSHostRect(*overlay);v.cursorLayer.contentsScale=v.window?v.window.backingScaleFactor:1;}
    [CATransaction commit];
    if(kind==2 && image && size.x>0 && size.y>0){
        NSImage *native=[[NSImage alloc] initWithCGImage:image size:NSMakeSize(size.x,size.y)];
        v.desktopCursor=[[NSCursor alloc] initWithImage:native hotSpot:NSMakePoint(hotspot.x,hotspot.y)];
    }else if(kind==1){
        static NSCursor *transparent;static dispatch_once_t once;
        dispatch_once(&once,^{NSImage *native=[[NSImage alloc] initWithSize:NSMakeSize(1,1)];transparent=[[NSCursor alloc] initWithImage:native hotSpot:NSZeroPoint];});
        v.desktopCursor=transparent;
    }else v.desktopCursor=NSCursor.arrowCursor;
    [v.window invalidateCursorRectsForView:v];
}
void sz_host_input(void *p,uint8_t kind,int32_t x,int32_t y,uint8_t display) {
    SZHostBox *box=(__bridge SZHostBox *)p;SpiceZigHostInput callbacks=box.callbacks;
    if(callbacks.input)callbacks.input(callbacks.context,kind,x,y,display);
}
void sz_host_failure(void *p,const char *category) { ((__bridge SZHostBox *)p).error=[NSString stringWithUTF8String:category]; }
int sz_host_location(void *p,SZHostPoint *out) { (void)p;CGEventRef e=CGEventCreate(NULL);if(!e)return 0;CGPoint point=CGEventGetLocation(e);CFRelease(e);*out=(SZHostPoint){point.x,point.y};return 1; }
int sz_host_disconnect(void *p) { (void)p;return CGAssociateMouseAndMouseCursorPosition(false)==kCGErrorSuccess; }
void sz_host_warp(void *p,SZHostPoint point) { (void)p;(void)CGWarpMouseCursorPosition(CGPointMake(point.x,point.y)); }
void sz_host_reconnect(void *p) { (void)p;(void)CGAssociateMouseAndMouseCursorPosition(true); }
void sz_host_hide(void *p) { (void)p;[NSCursor hide]; }
void sz_host_unhide(void *p) { (void)p;[NSCursor unhide]; }
void sz_host_cpu_pixels(void *cg,const uint8_t *bytes,size_t count,uint32_t width,uint32_t height,int alpha,SZHostRect rect) {
    CGImageRef image=SZImage(bytes,count,width,height,alpha);if(!image)return;
    CGContextRef context=cg;CGContextSaveGState(context);CGContextSetInterpolationQuality(context,kCGInterpolationNone);
    CGContextSetBlendMode(context,kCGBlendModeCopy);
    // Source rows are top-down; the owning NSView's coordinate system is flipped.
    CGContextTranslateCTM(context,rect.x,rect.y+rect.height);CGContextScaleCTM(context,1,-1);
    CGContextDrawImage(context,CGRectMake(0,0,rect.width,rect.height),image);CGContextRestoreGState(context);CGImageRelease(image);
}
void *spice_zig_host_view_create(SpiceZigSource *session,uint8_t channel,uint32_t surface,const char *library,const SpiceZigHostInput *callbacks) {
    if(!NSThread.isMainThread || !session)return NULL;
    if(callbacks && (!callbacks->context || !callbacks->retain || !callbacks->release || !callbacks->input))return NULL;
    SZHostView *view=[[SZHostView alloc] initWithFrame:NSMakeRect(0,0,640,480)];
    SZHostBox *box=[SZHostBox new];box.view=view;view.box=box;
    if(callbacks){callbacks->retain(callbacks->context);box.callbacks=*callbacks;}
    void *native=spice_zig_source_native_context(session);
    id<MTLDevice> device=(__bridge id<MTLDevice>)spice_zig_graphics_device(native);
    if(device){
        SZHostMetalView *metal=[[SZHostMetalView alloc] initWithFrame:view.bounds device:device];
        metal.paused=YES;metal.enableSetNeedsDisplay=NO;metal.autoResizeDrawable=NO;
        metal.framebufferOnly=NO;metal.colorPixelFormat=MTLPixelFormatBGRA8Unorm;metal.delegate=view;metal.hidden=YES;
        view.metal=metal;[view addSubview:metal positioned:NSWindowBelow relativeTo:view.overlay];
    }
    void *ownedBox=(__bridge_retained void *)box;
    view.controller=spice_zig_host_controller_create(session,ownedBox,channel,surface,library);
    if(!view.controller){sz_host_box_destroy(ownedBox);return NULL;}
    return (__bridge_retained void *)view;
}
void spice_zig_host_view_close(void *p) { if(p && NSThread.isMainThread)[(__bridge SZHostView *)p close]; }
void spice_zig_host_view_release(void *p) { if(p && NSThread.isMainThread){id owner=CFBridgingRelease(p);(void)owner;} }
const char *spice_zig_host_view_last_error(void *p) { return p&&NSThread.isMainThread?((__bridge SZHostView *)p).box.error.UTF8String:NULL; }
