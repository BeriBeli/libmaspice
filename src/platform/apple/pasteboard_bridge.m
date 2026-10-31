/* Narrow NSPasteboard and main-queue bridge. No protocol, retry or polling policy. */
#import <AppKit/AppKit.h>
#import <os/lock.h>
#import "pasteboard_bridge.h"
@interface SZPasteboardContext:NSObject { @public os_unfair_lock lock; BOOL pending; NSString *name; }
@end
@implementation SZPasteboardContext
@end
@interface SZPasteboardResult:NSObject { @public SpiceZigPasteboardInfo info; NSData *bytes; }
@end
@implementation SZPasteboardResult
@end
@interface SZPasteboardOperation:NSObject {
@public os_unfair_lock lock; SZPasteboardContext *owner; SZPasteboardResult *result;
NSString *text; BOOL writing,running,finished,cancelled; size_t maximum;
SpiceZigPasteboardComplete callback; void *context;
}
-(void)run;
-(void)finish:(int)status;
-(void)cancel;
@end
/* Foundation's UTF-8 initializer consumes one initial BOM. Input here represents
 * a Swift String's UTF-8, so restore that scalar; guest wire decoding is in Zig. */
static NSString *string(const uint8_t *bytes,size_t size) {
    if(!bytes && size)return nil;
    NSString *value=[[NSString alloc]initWithBytes:bytes?bytes:(const uint8_t *)"" length:size encoding:NSUTF8StringEncoding];
    if(value && size>=3 && bytes[0]==239 && bytes[1]==187 && bytes[2]==191){unichar bom=0xfeff;value=[[NSString stringWithCharacters:&bom length:1]stringByAppendingString:value];}
    return value;
}
static void releaseSlot(SZPasteboardContext *owner){os_unfair_lock_lock(&owner->lock);owner->pending=NO;os_unfair_lock_unlock(&owner->lock);}
@implementation SZPasteboardOperation
-(void)finish:(int)status {
    os_unfair_lock_lock(&lock);
    if(finished){os_unfair_lock_unlock(&lock);return;}
    finished=YES;
    if(cancelled)status=-2;
    SpiceZigPasteboardComplete complete=callback;void *user=context;
    callback=NULL;context=NULL;text=nil;
    void *output=status==0?(__bridge_retained void *)result:NULL;
    result=nil;
    os_unfair_lock_unlock(&lock);
    if(complete)complete(user,status,output);
}
-(void)cancel {
    os_unfair_lock_lock(&lock);
    if(finished){os_unfair_lock_unlock(&lock);return;}
    cancelled=YES;
    // Claim queued completion under the same lock used by run. Once cancel
    // returns its callback, run must be unable to begin an AppKit effect.
    SpiceZigPasteboardComplete complete=NULL;void *user=NULL;
    if(!running){finished=YES;complete=callback;user=context;callback=NULL;context=NULL;text=nil;result=nil;}
    os_unfair_lock_unlock(&lock);
    if(complete)complete(user,-2,NULL);
}
-(void)run {
    @autoreleasepool {
        NSCAssert([NSThread isMainThread],@"pasteboard runs on main");
        os_unfair_lock_lock(&lock);
        if(finished){os_unfair_lock_unlock(&lock);releaseSlot(owner);return;}
        running=YES;BOOL skip=cancelled;NSString *input=text;
        os_unfair_lock_unlock(&lock);
        int status=0;
        if(!skip){
            NSPasteboard *board=owner->name?[NSPasteboard pasteboardWithName:owner->name]:[NSPasteboard generalPasteboard];
            if(!board)status=-1;
            if(status==0 && writing){[board clearContents];if(![board setString:input forType:NSPasteboardTypeString])status=-3;}
            if(status==0){
                result->info.change_count=board.changeCount;
                NSString *value=[board stringForType:NSPasteboardTypeString];
                if(value){
                    result->info.present=1;result->info.size=[value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
                    if(result->info.size>maximum)result->info.oversized=1;
                    else {result->bytes=[value dataUsingEncoding:NSUTF8StringEncoding];if(!result->bytes || result->bytes.length!=result->info.size)status=-4;}
                }
            }
        }
        releaseSlot(owner);
        [self finish:skip?-2:status];
    }
}
@end
void *spice_zig_pb_create(const uint8_t *bytes,size_t size,int general){
    @autoreleasepool {
        if((general!=0 && general!=1) || (!general && (size==0 || size>4096)))return NULL;
        SZPasteboardContext *value=[SZPasteboardContext new];if(!value)return NULL;
        value->name=general?nil:string(bytes,size);if(!general && !value->name)return NULL;
        return (__bridge_retained void *)value;
    }
}
void spice_zig_pb_retain(void *p){if(p)CFRetain(p);}
void spice_zig_pb_destroy(void *p){if(p)CFRelease(p);}
int spice_zig_pb_pending(void *p){if(!p)return 0;SZPasteboardContext *owner=(__bridge SZPasteboardContext *)p;os_unfair_lock_lock(&owner->lock);BOOL pending=owner->pending;os_unfair_lock_unlock(&owner->lock);return pending;}
void *spice_zig_pb_begin(void *p,int writing,const uint8_t *bytes,size_t size,size_t maximum,SpiceZigPasteboardComplete callback,void *context,int *out_status){
    @autoreleasepool {
        if(out_status)*out_status=-1;
        if(!p || !callback || !out_status || (writing!=0 && writing!=1) || maximum>16*1024*1024)return NULL;
        SZPasteboardContext *owner=(__bridge SZPasteboardContext *)p;
        os_unfair_lock_lock(&owner->lock);BOOL busy=owner->pending;if(!busy)owner->pending=YES;os_unfair_lock_unlock(&owner->lock);
        if(busy){*out_status=-5;return NULL;}
        SZPasteboardOperation *operation=[SZPasteboardOperation new];SZPasteboardResult *result=[SZPasteboardResult new];
        NSString *input=writing?string(bytes,size):nil;
        if(!operation || !result || (writing && !input)){releaseSlot(owner);*out_status=writing && !input?-4:-1;return NULL;}
        operation->owner=owner;operation->result=result;operation->writing=writing;operation->text=input;operation->maximum=maximum;operation->callback=callback;operation->context=context;
        void *handle=(__bridge_retained void *)operation;*out_status=0;
        if([NSThread isMainThread])[operation run];else dispatch_async(dispatch_get_main_queue(),^{[operation run];});
        return handle;
    }
}
void spice_zig_pb_cancel(void *p){if(p)[(__bridge SZPasteboardOperation *)p cancel];}
void spice_zig_pb_operation_destroy(void *p){if(p)CFRelease(p);}
int spice_zig_pb_result_info(void *p,SpiceZigPasteboardInfo *out){if(!p || !out)return -1;*out=((__bridge SZPasteboardResult *)p)->info;return 0;}
const uint8_t *spice_zig_pb_result_bytes(void *p){return p?((__bridge SZPasteboardResult *)p)->bytes.bytes:NULL;}
void spice_zig_pb_result_destroy(void *p){if(p)CFRelease(p);}
