#include "spice_zig_desktop.h"
#include <CoreMedia/CoreMedia.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static OSStatus expected_status(int hevc){
    const uint8_t sps[]={0x67,1},pps[]={0x68,1},vps265[]={0x40,1,1},sps265[]={0x42,1,1},pps265[]={0x44,1,1};
    const uint8_t *parameters[]={hevc?vps265:sps,hevc?sps265:pps,pps265};
    size_t sizes[]={hevc?3:2,hevc?3:2,3};CMFormatDescriptionRef format=NULL;
    OSStatus status=hevc?CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault,3,parameters,sizes,4,NULL,&format):CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,2,parameters,sizes,4,&format);
    if(format)CFRelease(format);assert(status!=0&&status!=kCMFormatDescriptionError_AllocationFailed);return status;
}
int main(int argc,char **argv){
    assert(argc==3);int hevc=atoi(argv[2]);OSStatus native=expected_status(hevc);
    SpiceZigDesktop *desktop=NULL;assert(!spice_zig_desktop_create(NULL,hevc?2:1,&desktop));
    const uint8_t secret[]="synthetic-test";
    assert(!spice_zig_desktop_connect(desktop,"127.0.0.1",(uint16_t)strtoul(argv[1],NULL,10),0,NULL,NULL,NULL,0,3000,secret,sizeof(secret)-1));
    SpiceZigDesktopEvent *retained=NULL;SpiceZigDesktopEventMetadata captured;
    for(;;){
        SpiceZigDesktopEvent *event=NULL;assert(spice_zig_desktop_next(desktop,&event)==1);
        SpiceZigDesktopEventMetadata info;assert(!spice_zig_desktop_event_metadata(event,&info));
        if(info.kind==1){puts("ready");fflush(stdout);}
        if(info.kind==3){
            assert(info.detail==2&&info.channel_type==2&&info.channel_id==0);
            assert(info.values[0]==(unsigned)hevc&&info.values[1]==1&&(int32_t)info.values[2]==native);
            assert(!strcmp(spice_zig_desktop_event_error(event),"UnsupportedVideoFormat"));
            retained=event;captured=info;break;
        }
        assert(info.kind!=2);spice_zig_desktop_event_destroy(event);
    }
    spice_zig_desktop_cancel(desktop);spice_zig_desktop_join(desktop);
    assert(!spice_zig_desktop_reset(desktop,0));
    assert(spice_zig_desktop_connect(desktop,"127.0.0.1",0,0,NULL,NULL,NULL,0,3000,secret,sizeof(secret)-1)<0);
    SpiceZigDesktopEvent *generic=NULL;assert(spice_zig_desktop_next(desktop,&generic)==1);
    SpiceZigDesktopEventMetadata info;assert(!spice_zig_desktop_event_metadata(generic,&info));assert(info.kind==3&&!info.detail&&!info.values[1]);spice_zig_desktop_event_destroy(generic);
    spice_zig_desktop_destroy(desktop);
    assert(!spice_zig_desktop_event_metadata(retained,&info));assert(!memcmp(&captured,&info,sizeof(info)));spice_zig_desktop_event_destroy(retained);
    puts("typed video error preserves codec and native status after teardown; reset clears context");return 0;
}
