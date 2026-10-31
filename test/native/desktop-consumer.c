// Independent consumer uses only the public C header. No Zig/test-only handles.
#include "spice_zig_desktop.h"
#include "spice_zig_audio.h"
#include "spice_zig_pipeline.h"
#include <time.h>
_Static_assert(sizeof(SpiceZigPipelineTiming)==32,"pipeline histogram ABI");
_Static_assert(sizeof(SpiceZigAudioOptions)==24,"audio options ABI");
_Static_assert(sizeof(SpiceZigAudioEvent)==112,"audio event ABI");
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
_Static_assert(sizeof(SpiceZigDesktopEventMetadata)==216,"event ABI");
_Static_assert(sizeof(SpiceZigFrameInfo)==48,"frame ABI");
void *consumer_presenter_create(SpiceZigDesktop *,const char *);
void consumer_presenter_render(void *,const SpiceZigFrame *,uint8_t output[256]);
struct Pixels {SpiceZigFrame *frame;const uint8_t *bytes;size_t count;};
static void *read_pixels(void *p){struct Pixels *v=p;assert(!spice_zig_frame_pixels(v->frame,&v->bytes,&v->count));return NULL;}
int main(int argc,char **argv){
    assert(argc==6);unsigned port=(unsigned)strtoul(argv[1],NULL,10);int native=atoi(argv[2]);
    SpiceZigDesktop *desktop=NULL;assert(!spice_zig_desktop_create(native?argv[3]:NULL,0,&desktop));assert(desktop);
    SpiceZigAudioOptions audio_options;spice_zig_audio_options(&audio_options);assert(!audio_options.playback&&!audio_options.capture);
    SpiceZigAudio *audio_executor=NULL;assert(!spice_zig_audio_create(desktop,&audio_options,&audio_executor));
    const uint8_t secret[]="synthetic-test";
    assert(!spice_zig_desktop_connect(desktop,"127.0.0.1",(uint16_t)port,0,NULL,NULL,NULL,0,3000,secret,sizeof(secret)-1));
    SpiceZigDesktopInfo bootstrap;assert(!spice_zig_desktop_info(desktop,&bootstrap));assert(bootstrap.session_id==0x1234 && bootstrap.current_mouse_mode==2 && bootstrap.agent_connected && bootstrap.channel_count==8 && bootstrap.agent_epoch>0);
    for(size_t i=0;i<bootstrap.channel_count;i++){uint8_t type=0,id=0;assert(!spice_zig_desktop_channel(desktop,bootstrap.generation,i,&type,&id));assert(type>=2 && type<=11 && !id);}
    uint8_t type=0,id=0;assert(spice_zig_desktop_channel(desktop,bootstrap.generation+1,0,&type,&id)<0);
    SpiceZigFrame *frame=NULL,*second=NULL;SpiceZigDesktopEvent *cursor=NULL,*audio=NULL;unsigned received=0;
    while(received!=255){
        SpiceZigDesktopEvent *event=NULL;assert(spice_zig_desktop_next(desktop,&event)==1);assert(event);assert(!spice_zig_audio_observe(audio_executor,event));
        SpiceZigDesktopEventMetadata m;memset(&m,0xa5,sizeof(m));assert(!spice_zig_desktop_event_metadata(event,&m));assert(m.generation>0);
        if(m.kind==3){fprintf(stderr,"desktop failure: %s\n",spice_zig_desktop_event_error(event));abort();}
        size_t length=0;const uint8_t *data=spice_zig_desktop_event_data(event,&length);
        if(m.kind==1){
            assert(!spice_zig_desktop_set_demand(desktop,0,7,1));
            assert(!spice_zig_desktop_input(desktop,0,3,-2,4,0));
            SpiceZigDesktopSendToken *token=spice_zig_desktop_send_token_create();assert(token);
            assert(spice_zig_desktop_agent_at(desktop,bootstrap.lifecycle,bootstrap.agent_epoch+1,1,4,0,NULL,0,token)==-45);
            assert(spice_zig_desktop_agent_at(desktop,bootstrap.lifecycle+1,bootstrap.agent_epoch,1,4,0,NULL,0,token)==-45);
            spice_zig_desktop_send_token_cancel(token);
            assert(spice_zig_desktop_agent(desktop,1,4,0,NULL,0,token)==-31);spice_zig_desktop_send_token_destroy(token);
            puts("ready");fflush(stdout);
        }else if(m.kind==14){
            assert(m.values[0]==7 && m.values[1]==1 && m.values[2]==1 && m.wide[2]>0 && m.wide[3]>=m.wide[2]);
            assert(!spice_zig_desktop_event_frame(event,&frame));assert(!spice_zig_desktop_event_frame(event,&second));
            SpiceZigFrameInfo info;assert(!spice_zig_frame_info(frame,&info));assert(info.surface_id==7 && info.width==8 && info.height==8 && info.native==(unsigned)native && info.damage_count==1 && info.advanced_video==0 && info.reserved==0);
            SpiceZigDamageRect rect;assert(!spice_zig_frame_damage(frame,0,&rect));assert(rect.x==0 && rect.y==0 && rect.width==8 && rect.height==8);assert(spice_zig_frame_damage(frame,1,&rect)<0);
            assert((spice_zig_frame_texture(frame)!=NULL)==native);assert((spice_zig_frame_iosurface(frame)!=NULL)==native);
            assert(!spice_zig_desktop_acknowledge_frame(desktop,0,7,info.lifecycle,info.revision));received|=1;
        }else if(m.kind==8){
            assert(m.detail==1 && m.values[5]==1 && m.values[6]==0 && m.values[7]==2 && m.values[8]==1 && m.wide[0]==77);
            assert(length==8 && data[0]==1 && data[7]==8);cursor=event;event=NULL;received|=2;
        }else if(m.kind==9 && m.detail==5){assert(m.values[0]==32);for(unsigned i=0;i<32;i++)assert(m.values[i+1]==100+i);
        }else if(m.kind==9 && m.detail==3){
            assert(m.values[0]==120 && length==4 && data[3]==4);assert(!spice_zig_desktop_playback_delay(desktop,0,20));audio=event;event=NULL;received|=4;
        }else if(m.kind==10 && m.detail==2){
            const uint8_t pcm[]={1,2,3,4};assert(m.values[0]==2 && m.values[1]==1 && m.values[2]==48000 && m.wide[0]>0);
            assert(!spice_zig_desktop_record(desktop,0,1,11,NULL,0));assert(!spice_zig_desktop_record(desktop,0,0,12,pcm,sizeof(pcm)));received|=8;
        }else if(m.kind==11 && m.detail==3){
            assert(m.values[0]==3 && length==3 && !memcmp(data,"APD",3));assert(!spice_zig_desktop_smartcard(desktop,0,7,3,data,length));received|=16;
        }else if(m.kind==12){assert(length==3 && !memcmp(data,"USB",3));assert(!spice_zig_desktop_usb(desktop,0,data,length));received|=32;
        }else if(m.kind==13 && m.detail==3){assert((int64_t)m.wide[0]==-7 && length==3 && !memcmp(data,"DAV",3));assert(!spice_zig_desktop_webdav(desktop,0,-7,data,length));received|=64;
        }else if(m.kind==5 && m.detail==4){SpiceZigMonitor monitor;assert(m.values[0]==1 && m.values[1]==1);assert(!spice_zig_desktop_event_monitor(event,0,&monitor));assert(monitor.surface==7 && monitor.width==8);received|=128;}
        spice_zig_desktop_event_destroy(event);
    }
    void *presenter=native?consumer_presenter_create(desktop,argv[5]):NULL;
    SpiceZigAudioStatistics audio_stats;assert(!spice_zig_audio_statistics(audio_executor,&audio_stats));assert(!audio_stats.scheduled_packets&&!audio_stats.queued_capture_bytes);
    SpiceZigAudioEvent audio_event;assert(!spice_zig_audio_next(audio_executor,&audio_event));spice_zig_audio_stop(audio_executor);spice_zig_audio_destroy(audio_executor);
    SpiceZigPipelineMetrics metrics;
    for(unsigned retry=0;;retry++){
        assert(!spice_zig_desktop_pipeline_metrics(desktop,&metrics));
        if(metrics.publisher_emitted>=1 && (!native||metrics.mjpeg_decoded>=1))break;
        assert(retry<2000);struct timespec pause={0,1000000};nanosleep(&pause,NULL);
    }
    assert(metrics.display_channels==1&&metrics.damage_operations>=1&&metrics.damage_bytes>=256);
    assert(metrics.publisher_emitted_native==(unsigned)native&&metrics.publisher_emitted_cpu==(unsigned)!native);
    assert(metrics.receive_to_ready.count>=1&&metrics.snapshot_duration.count>=1&&metrics.emit_duration.count>=1);
    assert(metrics.cpu_materializations==0); /* first lazy readback remains after destroy */
    if(native){assert(metrics.mjpeg_handles==1&&metrics.mjpeg_decoded==1&&metrics.mjpeg_native==1&&metrics.mjpeg_allocations==1);
        assert(metrics.mjpeg_peak_buffers==1&&metrics.mjpeg_peak_decodes==1&&metrics.native_video_frames==1);}
    spice_zig_desktop_cancel(desktop);spice_zig_desktop_destroy(desktop);
    uint8_t presented[256];if(presenter)consumer_presenter_render(presenter,frame,presented);
    assert(frame && second && cursor && audio);assert(spice_zig_frame_retain(frame)==frame);spice_zig_frame_release(frame);
    // Concurrent first readback after the entire session and Surface pool died.
    struct Pixels reads[2]={{frame,NULL,0},{second,NULL,0}};pthread_t threads[2];
    for(unsigned i=0;i<2;i++)assert(!pthread_create(&threads[i],NULL,read_pixels,&reads[i]));
    for(unsigned i=0;i<2;i++)assert(!pthread_join(threads[i],NULL));
    assert(reads[0].count==256 && reads[0].bytes==reads[1].bytes);
    FILE *file=fopen(argv[4],"rb");assert(file);uint8_t expected[256];assert(fread(expected,1,sizeof(expected),file)==sizeof(expected));fclose(file);assert(!memcmp(reads[0].bytes,expected,sizeof(expected)));if(native)assert(!memcmp(presented,expected,sizeof(expected)));
    uint8_t copied[258];memset(copied,0xa5,sizeof(copied));
    assert(spice_zig_frame_copy_pixels(frame,copied+1,255)<0);
    for(size_t i=0;i<sizeof(copied);i++)assert(copied[i]==0xa5);
    assert(spice_zig_frame_copy_pixels(frame,NULL,256)<0);
    assert(!spice_zig_frame_copy_pixels(frame,copied+1,256));
    assert(copied[0]==0xa5&&copied[257]==0xa5&&!memcmp(copied+1,expected,256));
    memset(copied+1,0,256);assert(!memcmp(reads[0].bytes,expected,256));
    size_t length=0;const uint8_t *bytes=spice_zig_desktop_event_data(cursor,&length);assert(length==8 && bytes[7]==8);bytes=spice_zig_desktop_event_data(audio,&length);assert(length==4 && bytes[3]==4);
    spice_zig_desktop_event_destroy(cursor);spice_zig_desktop_event_destroy(audio);spice_zig_frame_release(second);spice_zig_frame_release(frame);
    spice_zig_desktop_destroy(NULL);spice_zig_frame_release(NULL);puts("public desktop C ABI lifetime and exact pixels passed");return 0;
}
