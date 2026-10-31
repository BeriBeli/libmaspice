#include "spice_zig_source.h"
#include "spice_zig_pipeline.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
static const uint8_t secret[]="synthetic-test";
static int connect_to(SpiceZigDesktop *desktop,unsigned port){
    return spice_zig_desktop_connect(desktop,"127.0.0.1",(uint16_t)port,0,NULL,NULL,NULL,0,3000,secret,sizeof(secret)-1);
}
static void drain(SpiceZigDesktop *desktop,SpiceZigSource *source,int failed){
    unsigned failures=0,disconnections=0;SpiceZigDesktopEvent *event=NULL;
    while(spice_zig_desktop_next(desktop,&event)==1){
        SpiceZigDesktopEventMetadata info;assert(!spice_zig_desktop_event_metadata(event,&info));
        assert(!spice_zig_source_observe(source,event));
        if(info.kind==3)failures++;
        if(info.kind==2)disconnections++;
        spice_zig_desktop_event_destroy(event);event=NULL;
    }
    assert(failures==(unsigned)failed&&disconnections==1);
    spice_zig_desktop_join(desktop);
}
static void pixel(SpiceZigFrame *frame,unsigned expected){
    const uint8_t *bytes=NULL;size_t count=0;
    assert(!spice_zig_frame_pixels(frame,&bytes,&count)&&count==256);
    for(unsigned i=0;i<64;i++){assert(bytes[i*4]==expected&&bytes[i*4+1]==0&&bytes[i*4+2]==0&&bytes[i*4+3]==255);}
}
int main(int argc,char **argv){
    assert(argc==4);SpiceZigDesktop *desktop=NULL;SpiceZigSource *source=NULL;SpiceZigSubscription *subscription=NULL;
    assert(!spice_zig_desktop_create(NULL,0,&desktop));
    SpiceZigSourceOptions options;spice_zig_source_options(&options);
    assert(!spice_zig_source_create(desktop,&options,&source));
    assert(!spice_zig_source_subscribe(source,0,7,&subscription));
    assert(!spice_zig_subscription_demand(subscription,1));
    assert(!spice_zig_desktop_reset(desktop,1)); /* initial policy selection */
    SpiceZigDesktopEvent *old_event=NULL;SpiceZigFrame *old_frame=NULL;
    uint64_t previous_generation=0,previous_lifecycle=0;
    for(unsigned run=0;run<2;run++){
        if(run){
            assert(!spice_zig_desktop_reset(desktop,0));
            SpiceZigPipelineMetrics empty;assert(!spice_zig_desktop_pipeline_metrics(desktop,&empty));
            assert(!empty.display_channels&&!empty.damage_operations&&!empty.surface_bytes);
            assert(connect_to(desktop,(unsigned)strtoul(argv[2],NULL,10))==-37);
            drain(desktop,source,1);
            assert(!spice_zig_desktop_reset(desktop,0));
        }
        assert(!connect_to(desktop,(unsigned)strtoul(argv[run?3:1],NULL,10)));
        SpiceZigDesktopInfo bootstrap;assert(!spice_zig_desktop_info(desktop,&bootstrap));
        assert(bootstrap.generation>previous_generation&&bootstrap.lifecycle>previous_lifecycle);
        previous_generation=bootstrap.generation;previous_lifecycle=bootstrap.lifecycle;
        assert(spice_zig_desktop_reset(desktop,0)<0); /* cannot reset a live run */
        assert(spice_zig_desktop_reset(desktop,3)<0);
        int frame_received=0;
        while(!frame_received){
            SpiceZigDesktopEvent *event=NULL;assert(spice_zig_desktop_next(desktop,&event)==1);
            SpiceZigDesktopEventMetadata info;assert(!spice_zig_desktop_event_metadata(event,&info));
            assert(info.kind!=2&&info.kind!=3);assert(!spice_zig_source_observe(source,event));
            if(info.kind==1){
                if(old_event){
                    SpiceZigSourceMetrics before,after;
                    assert(!spice_zig_source_metrics(source,&before));assert(!spice_zig_source_observe(source,old_event));assert(!spice_zig_source_metrics(source,&after));
                    assert(before.delivered==after.delivered);
                }
                printf("ready %u\n",run);fflush(stdout);
            }
            if(info.kind==14){
                SpiceZigSnapshot *snapshot=NULL;assert(spice_zig_subscription_next(subscription,1,&snapshot)==1);
                SpiceZigFrame *frame=NULL;assert(spice_zig_snapshot_frame(snapshot,&frame)==1);pixel(frame,run?0x22:0x11);
                if(!run){old_frame=frame;frame=NULL;old_event=event;event=NULL;}
                else pixel(old_frame,0x11);
                spice_zig_frame_release(frame);spice_zig_snapshot_destroy(snapshot);frame_received=1;
            }
            spice_zig_desktop_event_destroy(event);
        }
        SpiceZigPipelineMetrics metrics;assert(!spice_zig_desktop_pipeline_metrics(desktop,&metrics));
        assert(metrics.display_channels==1&&metrics.damage_operations==1&&metrics.damage_bytes==256);
        spice_zig_desktop_cancel(desktop);drain(desktop,source,0);
        SpiceZigSnapshot *cleared=NULL;assert(spice_zig_subscription_next(subscription,0,&cleared)==1);
        SpiceZigSnapshotInfo info;assert(!spice_zig_snapshot_info(cleared,&info)&&!info.has_frame);spice_zig_snapshot_destroy(cleared);
        assert(!spice_zig_desktop_pipeline_metrics(desktop,&metrics));assert(metrics.display_channels==1&&!metrics.surface_bytes);
        printf("stopped %u\n",run);fflush(stdout);
    }
    spice_zig_desktop_event_destroy(old_event);spice_zig_frame_release(old_frame);
    spice_zig_source_destroy(source);spice_zig_desktop_destroy(desktop);
    spice_zig_subscription_destroy(subscription);
    puts("reconnect, failed authentication recovery, stable Source and stale-event fencing passed");return 0;
}
