#import <AppKit/AppKit.h>
#include "pasteboard_bridge.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>
struct Probe { _Atomic int done; int status; void *result; };
static void complete(void *p,int status,void *result){struct Probe *probe=p;assert(!atomic_load(&probe->done));probe->status=status;probe->result=result;atomic_store(&probe->done,1);}
struct Start {void *context;struct Probe *probe;_Atomic(void *) operation;};
static void *start(void *p){struct Start *job=p;int status=0;void *op=spice_zig_pb_begin(job->context,1,(const uint8_t *)"must-not-write",14,100,complete,job->probe,&status);assert(op && !status);atomic_store(&job->operation,op);return NULL;}
static void drain(void){__block BOOL done=NO;dispatch_async(dispatch_get_main_queue(),^{done=YES;});NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];while(!done && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];assert(done);}
int main(void){@autoreleasepool{
    NSPasteboard *board=[NSPasteboard pasteboardWithUniqueName];NSData *name=[board.name dataUsingEncoding:NSUTF8StringEncoding];
    for(unsigned i=0;i<32;i++){
        [board clearContents];assert([board setString:@"original" forType:NSPasteboardTypeString]);NSInteger change=board.changeCount;
        void *context=spice_zig_pb_create(name.bytes,name.length,0);assert(context);struct Probe *probe=calloc(1,sizeof(*probe));assert(probe);struct Start job={.context=context,.probe=probe};pthread_t worker;assert(!pthread_create(&worker,NULL,start,&job));
        for(unsigned n=0;n<3000 && !atomic_load(&job.operation);n++)usleep(1000);assert(atomic_load(&job.operation));assert(!pthread_join(worker,NULL));
        void *operation=atomic_load(&job.operation);spice_zig_pb_cancel(operation);assert(atomic_load(&probe->done) && probe->status==-2 && !probe->result);free(probe);
        spice_zig_pb_operation_destroy(operation);spice_zig_pb_destroy(context);drain();assert(board.changeCount==change);assert([[board stringForType:NSPasteboardTypeString]isEqualToString:@"original"]);
    }
    [board releaseGlobally];puts("32 queued native pasteboard cancellations release callback/context before main drain with ASan/UBSan");
}return 0;}
