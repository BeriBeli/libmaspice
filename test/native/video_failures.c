#include <stdint.h>
#include <stdatomic.h>
// Test-only wrappers around real Apple calls; production bridge has no hooks.
int32_t video_native_session(void *,void **);
int32_t video_native_hardware(void *,int *);
static _Atomic(int) next_session_failure;
static _Atomic(int) next_hardware;
void video_probe_fail_session(void){atomic_store(&next_session_failure,1);}
void video_probe_hardware(int mode){atomic_store(&next_hardware,mode);}
int32_t spice_zig_video_session(void *format,void **output){
    if(atomic_exchange(&next_session_failure,0)){*output=0;return -12907;}return video_native_session(format,output);
}
int32_t spice_zig_video_hardware(void *session,int *hardware){
    int mode=atomic_exchange(&next_hardware,0);
    if(mode==1){*hardware=0;return 0;}
    if(mode==2){*hardware=0;return -1;}
    return video_native_hardware(session,hardware);
}
