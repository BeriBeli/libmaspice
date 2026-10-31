#include "spice_zig_diagnostics.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
_Static_assert(sizeof(SpiceZigTraceIdentity)==40,"trace identity ABI");
_Static_assert(sizeof(SpiceZigTimingSummary)==32,"timing summary ABI");
struct Client {SpiceZigDesktop *desktop;SpiceZigSource *source;SpiceZigSubscription *subscription;pthread_mutex_t mutex;pthread_cond_t changed;unsigned frames;_Atomic int stopping;};
static void *receive(void *raw) {
 struct Client *self=raw;
 while(!atomic_load(&self->stopping)) {
  SpiceZigDesktopEvent *event=NULL;int result=spice_zig_desktop_next(self->desktop,&event);
  if(atomic_load(&self->stopping)){spice_zig_desktop_event_destroy(event);break;}
  assert(result==1);SpiceZigDesktopEventMetadata info;assert(!spice_zig_desktop_event_metadata(event,&info));assert(info.kind!=2&&info.kind!=3);
  assert(!spice_zig_source_observe(self->source,event));
  if(info.kind==1){puts("ready");fflush(stdout);}
  if(info.kind==14){assert(!pthread_mutex_lock(&self->mutex));self->frames++;assert(!pthread_cond_broadcast(&self->changed));assert(!pthread_mutex_unlock(&self->mutex));}
  spice_zig_desktop_event_destroy(event);
 }
 return NULL;
}
static SpiceZigTraceString str(const char *text){return (SpiceZigTraceString){(const uint8_t *)text,strlen(text)};}
int main(int argc,char **argv) {
 assert(argc==5);struct Client self={.mutex=PTHREAD_MUTEX_INITIALIZER,.changed=PTHREAD_COND_INITIALIZER};
 assert(!spice_zig_desktop_create(atoi(argv[2])?argv[3]:NULL,0,&self.desktop));
 SpiceZigSourceOptions options;spice_zig_source_options(&options);assert(!spice_zig_source_create(self.desktop,&options,&self.source));
 SpiceZigDiagnostics *diagnostics=NULL;assert(!spice_zig_source_diagnostics(self.source,&diagnostics));
 assert(!spice_zig_source_subscribe(self.source,0,7,&self.subscription));assert(!spice_zig_subscription_demand(self.subscription,1));
 SpiceZigSnapshot *initial=NULL;assert(spice_zig_subscription_next(self.subscription,0,&initial)==1);spice_zig_snapshot_destroy(initial);
 const uint8_t secret[]="synthetic-test";
 assert(!spice_zig_desktop_connect(self.desktop,"127.0.0.1",(uint16_t)strtoul(argv[1],NULL,10),0,NULL,NULL,NULL,0,3000,secret,sizeof(secret)-1));
 pthread_t thread;assert(!pthread_create(&thread,NULL,receive,&self));char command[64];assert(fgets(command,sizeof(command),stdin)&&!strcmp(command,"arm\n"));
 SpiceZigTraceConfig config={.pair_id=str("pair"),.version=str("zig"),.run_id=str("tcp"),.token=str("0123456789abcdef"),.path=str(argv[4]),.order=1,.action=0,.checksum=0xaabbccdd};
 SpiceZigTraceCapture *capture=NULL;const char *category=NULL;assert(!spice_zig_trace_create(diagnostics,&config,&capture,&category)&&!category);
 SpiceZigTraceCapture *duplicate=(void *)1;assert(spice_zig_trace_create(diagnostics,&config,&duplicate,&category)==-62&&!duplicate);assert(category&&!strcmp(category,"CaptureAlreadyActive"));
 SpiceZigDesktopSendToken *token=spice_zig_desktop_send_token_create();assert(token);spice_zig_desktop_send_token_cancel(token);SpiceZigTraceIdentity identity;
 assert(spice_zig_trace_wait(capture,token,&identity)==-31);spice_zig_desktop_send_token_destroy(token);
 uint64_t host=spice_zig_diagnostics_now_ns();assert(host);assert(!spice_zig_trace_host_input(capture,host,host,host));assert(!spice_zig_trace_send_completed(capture,spice_zig_diagnostics_now_ns(),NULL));assert(!spice_zig_trace_guest(capture,20,30,9));puts("armed");fflush(stdout);
 assert(fgets(command,sizeof(command),stdin)&&!strcmp(command,"frame\n"));
 struct timespec limit;assert(!clock_gettime(CLOCK_REALTIME,&limit));limit.tv_sec+=8;assert(!pthread_mutex_lock(&self.mutex));while(!self.frames)assert(!pthread_cond_timedwait(&self.changed,&self.mutex,&limit));assert(!pthread_mutex_unlock(&self.mutex));
 SpiceZigSnapshot *snapshot=NULL;assert(spice_zig_subscription_next(self.subscription,1,&snapshot)==1);assert(spice_zig_snapshot_trace_identity(snapshot,&identity)==1);
 SpiceZigFrame *frame=NULL;assert(spice_zig_snapshot_frame(snapshot,&frame)==1);SpiceZigFrameInfo info;assert(!spice_zig_frame_info(frame,&info));assert(info.width==400&&info.height==48&&info.native==(unsigned)atoi(argv[2]));spice_zig_frame_release(frame);
 // Cursor-only/authoritative redelivery uses original frame identity, without
 // a second marker observation that would incorrectly mark it a duplicate.
 assert(!spice_zig_subscription_request_latest(self.subscription));SpiceZigSnapshot *again=NULL;assert(spice_zig_subscription_next(self.subscription,1,&again)==1);SpiceZigTraceIdentity same;assert(spice_zig_snapshot_trace_identity(again,&same)==1);assert(!memcmp(&identity,&same,sizeof(same)));spice_zig_snapshot_destroy(again);
 uint64_t epoch=spice_zig_diagnostics_epoch(diagnostics),selected=spice_zig_diagnostics_now_ns();
 assert(!spice_zig_diagnostics_trace_stage(diagnostics,SPICE_ZIG_TRACE_SELECTED,&identity,selected,selected));
 assert(!spice_zig_diagnostics_trace_stage(diagnostics,SPICE_ZIG_TRACE_COMMITTED,&identity,spice_zig_diagnostics_now_ns(),0));
 assert(!spice_zig_diagnostics_trace_stage(diagnostics,SPICE_ZIG_TRACE_DROPPED,&identity,0,0));
 assert(!spice_zig_diagnostics_trace_stage(diagnostics,SPICE_ZIG_TRACE_SELECTED,&identity,selected,selected));
 assert(!spice_zig_diagnostics_trace_stage(diagnostics,SPICE_ZIG_TRACE_COMMITTED,&identity,spice_zig_diagnostics_now_ns(),0));
 uint64_t presented=spice_zig_diagnostics_now_ns();assert(!spice_zig_diagnostics_trace_stage(diagnostics,SPICE_ZIG_TRACE_PRESENTED,&identity,presented,0));
 token=spice_zig_desktop_send_token_create();assert(token);SpiceZigTraceIdentity accepted;assert(!spice_zig_trace_wait(capture,token,&accepted));assert(!memcmp(&identity,&accepted,sizeof(identity)));spice_zig_desktop_send_token_destroy(token);
 assert(!spice_zig_diagnostics_presented(diagnostics,1,&epoch));assert(!spice_zig_diagnostics_interval(diagnostics,SPICE_ZIG_REQUEST_TO_PRESENTED,selected,presented,&epoch));
 SpiceZigPresentationMetrics metrics;assert(!spice_zig_diagnostics_metrics(diagnostics,&metrics));assert(metrics.counters[SPICE_ZIG_METAL_PRESENTED]==1&&metrics.counters[SPICE_ZIG_ADVANCED_PRESENTED]==1&&metrics.latency[SPICE_ZIG_REQUEST_TO_PRESENTED].count==1&&!metrics.latency[SPICE_ZIG_COMMIT_TO_COMPLETION].count);
 spice_zig_diagnostics_reset(diagnostics);assert(!spice_zig_diagnostics_presented(diagnostics,1,&epoch));assert(!spice_zig_diagnostics_metrics(diagnostics,&metrics));assert(!metrics.counters[SPICE_ZIG_METAL_PRESENTED]);
 spice_zig_snapshot_destroy(snapshot);atomic_store(&self.stopping,1);spice_zig_desktop_cancel(self.desktop);assert(!pthread_join(thread,NULL));
 spice_zig_subscription_destroy(self.subscription);spice_zig_source_destroy(self.source);spice_zig_desktop_destroy(self.desktop);spice_zig_diagnostics_destroy(diagnostics);
 // Capture registry survives its Source and Desktop; final record survives it.
 SpiceZigTraceRecord *record=NULL;assert(!spice_zig_trace_finish(capture,(SpiceZigTraceString){0},&record,&category)&&!category);spice_zig_trace_destroy(capture);
 const uint8_t *bytes=NULL;size_t count=0;assert(!spice_zig_trace_record_bytes(record,&bytes,&count));assert(count>0);assert(fwrite(bytes,1,count,stdout)==count);putchar('\n');spice_zig_trace_record_destroy(record);
 assert(!pthread_cond_destroy(&self.changed));assert(!pthread_mutex_destroy(&self.mutex));return 0;
}
