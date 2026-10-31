#import <AppKit/AppKit.h>
void *pasteboard_probe_create(void){return (__bridge_retained void *)[NSPasteboard pasteboardWithUniqueName];}
const char *pasteboard_probe_name(void *p){return ((__bridge NSPasteboard *)p).name.UTF8String;}
void pasteboard_probe_destroy(void *p){NSPasteboard *board=(__bridge_transfer NSPasteboard *)p;[board releaseGlobally];}
int pasteboard_probe_drain(void){
    __block BOOL drained=NO;dispatch_async(dispatch_get_main_queue(),^{drained=YES;});
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
    while(!drained && [deadline timeIntervalSinceNow]>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return drained;
}

int pasteboard_probe_matches(void *p,const unsigned char *bytes,size_t size){
    NSData *actual=[[(__bridge NSPasteboard *)p stringForType:NSPasteboardTypeString] dataUsingEncoding:NSUTF8StringEncoding];
    return actual && actual.length==size && (size==0 || memcmp(actual.bytes,bytes,size)==0);
}
