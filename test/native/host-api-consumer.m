#import <AppKit/AppKit.h>
#include "spice_zig_host_view.h"
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
typedef struct {_Atomic(unsigned) refs;} State;
static void retainState(void *p){atomic_fetch_add(&((State *)p)->refs,1);}
static void releaseState(void *p){assert(atomic_fetch_sub(&((State *)p)->refs,1)>1);}
static void input(void *p,uint8_t kind,int32_t x,int32_t y,uint8_t display){(void)p;(void)kind;(void)x;(void)y;(void)display;}
int main(int argc,char **argv){
    assert(argc==3);
    for(unsigned native=0;native<2;native++){
        State state={.refs=1};
        @autoreleasepool {
            SpiceZigDesktop *desktop=NULL;assert(!spice_zig_desktop_create(native?argv[1]:NULL,0,&desktop));
            SpiceZigSourceOptions options;spice_zig_source_options(&options);
            SpiceZigSource *source=NULL;assert(!spice_zig_source_create(desktop,&options,&source));
            SpiceZigHostInput callbacks={&state,retainState,releaseState,input};
            void *view=spice_zig_host_view_create(source,0,0,argv[2],&callbacks);assert(view);
            SpiceZigSourceMetrics metrics;assert(!spice_zig_source_metrics(source,&metrics));assert(metrics.subscriptions==1 && !metrics.visible);
            spice_zig_source_destroy(source);spice_zig_desktop_destroy(desktop);
            spice_zig_host_view_close(view);spice_zig_host_view_release(view);
        }
        assert(atomic_load(&state.refs)==1);
    }
    puts("public host archive: actual Desktop/Source integration, CPU/native ownership and destruction passed");
    return 0;
}
