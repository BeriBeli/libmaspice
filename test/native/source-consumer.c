#include "spice_zig_source.h"
#include "spice_zig_pipeline.h"
_Static_assert(sizeof(SpiceZigPipelineMetrics)==720,"pipeline metrics ABI");
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
_Static_assert(sizeof(SpiceZigSnapshotInfo)==48,"snapshot info ABI");
_Static_assert(sizeof(SpiceZigSnapshotCursor)==56,"cursor info ABI");
struct Client {
    SpiceZigDesktop *desktop; SpiceZigSource *source; SpiceZigSubscription *subscription;
    SpiceZigReady *ready; SpiceZigSnapshot *retained;
    pthread_mutex_t mutex; pthread_cond_t changed; unsigned frames,cursors;
    _Atomic int stopping,handler_refs,handler_calls;
};
static void wait_count(struct Client *self,int cursor,unsigned count) {
    struct timespec limit;assert(!clock_gettime(CLOCK_REALTIME,&limit));limit.tv_sec+=8;
    assert(!pthread_mutex_lock(&self->mutex));
    while((cursor?self->cursors:self->frames)<count)assert(!pthread_cond_timedwait(&self->changed,&self->mutex,&limit));
    assert(!pthread_mutex_unlock(&self->mutex));
}
static void *receive(void *raw) {
    struct Client *self=raw;SpiceZigDesktopEvent *old=NULL;
    while(!atomic_load(&self->stopping)) {
        SpiceZigDesktopEvent *event=NULL;int result=spice_zig_desktop_next(self->desktop,&event);
        if(atomic_load(&self->stopping)){spice_zig_desktop_event_destroy(event);break;}
        assert(result==1);SpiceZigDesktopEventMetadata info;assert(!spice_zig_desktop_event_metadata(event,&info));assert(info.kind!=2&&info.kind!=3);
        assert(!spice_zig_source_observe(self->source,event));
        if(info.kind==1){puts("ready");fflush(stdout);}
        if(info.kind==14||info.kind==8){
            assert(!pthread_mutex_lock(&self->mutex));if(info.kind==14)self->frames++;else self->cursors++;
            assert(!pthread_cond_broadcast(&self->changed));assert(!pthread_mutex_unlock(&self->mutex));
        }
        if(info.kind==6){
            assert(info.values[4]==(info.values[3]==1?9u:0u));
            size_t subject_size=999;const uint8_t *subject=spice_zig_desktop_event_migration_subject(event,&subject_size);
            if(info.values[5])assert(subject&&subject_size==16&&!memcmp(subject,"CN=guest.example",16));
            else assert(!subject&&!subject_size);
        }
        if(info.kind==6&&info.detail==7){
            assert(info.values[5]==1);
            SpiceZigPipelineMetrics metrics;assert(!spice_zig_desktop_pipeline_metrics(self->desktop,&metrics));
            assert(metrics.display_channels==1&&metrics.damage_operations==1&&metrics.surface_bytes==256);
            puts("migration_failed");fflush(stdout);
        }
        if(info.kind==6&&info.detail==6){
            SpiceZigSourceMetrics before,after;assert(!spice_zig_source_metrics(self->source,&before));assert(old);
            assert(!spice_zig_source_observe(self->source,old));assert(!spice_zig_source_metrics(self->source,&after));
            assert(before.delivered==after.delivered);puts("migrated");fflush(stdout);
        }
        if(info.kind==14&&!old){old=event;event=NULL;}
        spice_zig_desktop_event_destroy(event);
    }
    spice_zig_desktop_event_destroy(old);return NULL;
}
static SpiceZigSnapshot *next(struct Client *self) {
    SpiceZigSnapshot *result=NULL;assert(spice_zig_subscription_next(self->subscription,1,&result)==1);assert(result);return result;
}
static void assert_pixels(const SpiceZigSnapshot *snapshot,int full) {
    SpiceZigFrame *frame=NULL;assert(spice_zig_snapshot_frame(snapshot,&frame)==1);SpiceZigFrameInfo info;
    assert(!spice_zig_frame_info(frame,&info));assert(info.width==8&&info.height==8&&info.surface_id==7);
    if(full){SpiceZigDamageRect rect;assert(info.damage_count==1);assert(!spice_zig_frame_damage(frame,0,&rect));assert(!rect.x&&!rect.y&&rect.width==8&&rect.height==8);}
    else assert(!info.damage_count);
    const uint8_t *bytes=NULL;size_t count=0;assert(!spice_zig_frame_pixels(frame,&bytes,&count));assert(count==256);
    for(unsigned i=0;i<64;i++){assert(bytes[i*4]==0x33&&bytes[i*4+1]==0x22&&bytes[i*4+2]==0x11&&bytes[i*4+3]==255);}
    spice_zig_frame_release(frame);
}
static void retain_handler(void *raw){struct Client *self=raw;atomic_fetch_add(&self->handler_refs,1);}
static void release_handler(void *raw){struct Client *self=raw;atomic_fetch_sub(&self->handler_refs,1);}
static void emit(void *raw,const SpiceZigSnapshot *snapshot) {
    struct Client *self=raw;SpiceZigSnapshotInfo info;assert(!spice_zig_snapshot_info(snapshot,&info));assert(info.has_frame);
    assert(spice_zig_ready_offer(self->ready,snapshot,100)>=0);atomic_fetch_add(&self->handler_calls,1);
    SpiceZigFrame *frame=NULL;assert(spice_zig_snapshot_frame(snapshot,&frame)==1);SpiceZigFrameInfo fi;assert(!spice_zig_frame_info(frame,&fi));
    assert(!spice_zig_subscription_acknowledge(self->subscription,info.frame_session,info.channel_id,fi.surface_id,fi.lifecycle,fi.revision));spice_zig_frame_release(frame);
}
int main(int argc,char **argv) {
    assert(argc==4);struct Client self={.mutex=PTHREAD_MUTEX_INITIALIZER,.changed=PTHREAD_COND_INITIALIZER};
    assert(!spice_zig_desktop_create(atoi(argv[2])?argv[3]:NULL,0,&self.desktop));
    SpiceZigSourceOptions options;spice_zig_source_options(&options);assert(!spice_zig_source_create(self.desktop,&options,&self.source));
    assert(!spice_zig_source_subscribe(self.source,0,7,&self.subscription));assert(!spice_zig_subscription_demand(self.subscription,1));
    SpiceZigSnapshot *initial=next(&self);spice_zig_snapshot_destroy(initial);
    const uint8_t secret[]="synthetic-test";
    assert(!spice_zig_desktop_connect(self.desktop,"127.0.0.1",(uint16_t)strtoul(argv[1],NULL,10),0,NULL,NULL,NULL,0,3000,secret,sizeof(secret)-1));
    pthread_t thread;assert(!pthread_create(&thread,NULL,receive,&self));
    char command[64];
    while(fgets(command,sizeof(command),stdin)) {
        if(!strcmp(command,"stop\n"))break;
        if(!strcmp(command,"frame\n")) {
            wait_count(&self,0,1);SpiceZigSnapshot *snapshot=next(&self);assert_pixels(snapshot,1);assert(!spice_zig_snapshot_clone(snapshot,&self.retained));spice_zig_snapshot_destroy(snapshot);puts("frame");
        }else if(!strcmp(command,"cursor\n")) {
            wait_count(&self,1,1);SpiceZigSnapshot *snapshot=next(&self);assert_pixels(snapshot,0);
            SpiceZigSnapshotCursor cursor;const uint8_t *bytes=NULL;size_t size=0;assert(spice_zig_snapshot_cursor(snapshot,&cursor,&bytes,&size)==1);
            assert(cursor.x==10&&cursor.y==20&&cursor.visible&&cursor.unique==77&&size==8&&bytes[7]==8);spice_zig_snapshot_destroy(snapshot);puts("cursor");
        }else if(!strcmp(command,"hidden\n")) {
            assert(!spice_zig_subscription_demand(self.subscription,0));SpiceZigSnapshot *pending=NULL;int found=spice_zig_subscription_next(self.subscription,0,&pending);assert(found>=0);spice_zig_snapshot_destroy(pending);puts("hidden");
        }else if(!strcmp(command,"visible\n")) {
            assert(!spice_zig_subscription_demand(self.subscription,1));SpiceZigSnapshot *snapshot=next(&self);assert_pixels(snapshot,1);spice_zig_snapshot_destroy(snapshot);puts("visible");
        }else if(!strcmp(command,"handler\n")) {
            self.ready=spice_zig_ready_create();assert(self.ready);SpiceZigSourceHandler handler={&self,retain_handler,release_handler,emit};
            assert(!spice_zig_subscription_handler(self.subscription,&handler));assert(atomic_load(&self.handler_refs)==1);
            assert(!spice_zig_subscription_request_latest(self.subscription));assert(atomic_load(&self.handler_calls)>=1);
            SpiceZigSnapshot *snapshot=NULL;uint64_t ready=0,waiting=0;assert(spice_zig_ready_take(self.ready,150,&snapshot,&ready,&waiting)==1);assert(ready==100&&waiting==50);assert_pixels(snapshot,1);
            assert(spice_zig_ready_offer(self.ready,snapshot,160)==0);assert(spice_zig_ready_restore(self.ready,snapshot,100)==1);spice_zig_ready_discard(self.ready);
            assert(!spice_zig_subscription_handler(self.subscription,NULL));assert(!atomic_load(&self.handler_refs));spice_zig_snapshot_destroy(snapshot);spice_zig_ready_destroy(self.ready);self.ready=NULL;puts("handler");
        }else if(!strncmp(command,"migration ",10)) {
            int switching=atoi(command+10);SpiceZigSnapshot *snapshot=next(&self);SpiceZigSnapshotInfo info,old;assert(!spice_zig_snapshot_info(snapshot,&info));assert(!spice_zig_snapshot_info(self.retained,&old));assert(info.generation>old.generation);
            if(switching)assert(!info.has_frame);else{assert(info.frame_session==old.frame_session);assert_pixels(snapshot,1);}
            SpiceZigPipelineMetrics metrics,again;
            assert(!spice_zig_desktop_pipeline_metrics(self.desktop,&metrics));
            assert(!spice_zig_desktop_pipeline_metrics(self.desktop,&again));
            assert(metrics.display_channels==(unsigned)(switching?2:1)&&again.display_channels==metrics.display_channels);
            assert(metrics.damage_operations==1&&metrics.damage_bytes==256&&metrics.full_copy_bytes==256);
            assert(metrics.publisher_emitted_cpu>=1&&metrics.publisher_emitted_native==0);
            assert(metrics.receive_to_ready.count==1&&metrics.receive_to_ready.has_values);
            assert(metrics.surface_bytes==(unsigned)(switching?0:256)&&metrics.maximum_surface_bytes==256*1024*1024);
            spice_zig_snapshot_destroy(snapshot);puts("migration");
        }else abort();
        fflush(stdout);
    }
    atomic_store(&self.stopping,1);spice_zig_desktop_cancel(self.desktop);assert(!pthread_join(thread,NULL));
    assert(!spice_zig_source_status(self.source,NULL));spice_zig_source_destroy(self.source);spice_zig_desktop_destroy(self.desktop);
    assert_pixels(self.retained,1);spice_zig_snapshot_destroy(self.retained);
    assert(!spice_zig_subscription_request_latest(self.subscription));SpiceZigSnapshot *after=next(&self);spice_zig_snapshot_destroy(after);
    spice_zig_subscription_cancel(self.subscription);SpiceZigSnapshot *empty=(void *)1;assert(!spice_zig_subscription_next(self.subscription,1,&empty)&&!empty);spice_zig_subscription_destroy(self.subscription);
    assert(!pthread_cond_destroy(&self.changed));assert(!pthread_mutex_destroy(&self.mutex));puts("public Source subscriptions and retained snapshots passed");return 0;
}
