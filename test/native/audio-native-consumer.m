/* Native boundary sanitizer test. Imports the implementation to exercise its
 * private callback lease without starting a hardware engine or requesting mic. */
#import "../../src/platform/apple/audio_bridge.m"
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>
extern void *audio_probe_format(uint32_t,uint32_t,uint32_t,uint32_t);
extern void *audio_probe_input(void *,uint32_t,uint32_t);
extern void audio_probe_release(void *);
typedef struct {pthread_mutex_t mutex;pthread_cond_t changed;bool entered,released;unsigned calls;} Context;
typedef struct {void *gate;Context *context;atomic_bool closeStarted,closeFinished;} Work;
static void *callback(void *raw){Work *w=raw;SZAudioGate *gate=(__bridge SZAudioGate *)w->gate;if([gate enter]){
 Context *c=gate->context;pthread_mutex_lock(&c->mutex);c->entered=true;pthread_cond_broadcast(&c->changed);while(!c->released)pthread_cond_wait(&c->changed,&c->mutex);c->calls++;pthread_mutex_unlock(&c->mutex);[gate leave];}return NULL;}
static void *closer(void *raw){Work *w=raw;atomic_store(&w->closeStarted,true);[(__bridge SZAudioGate *)w->gate close];atomic_store(&w->closeFinished,true);return NULL;}
typedef struct {unsigned calls;uint32_t next;} Render;
static void renderPCM(void *raw,uint32_t frames,void *rawList){
 Render *state=raw;AudioBufferList *list=rawList;assert(list->mNumberBuffers==1&&list->mBuffers[0].mDataByteSize>=frames*4);
 int16_t *samples=list->mBuffers[0].mData;for(uint32_t i=0;i<frames*2;i++)samples[i]=(int16_t)((state->next++%512)-256);state->calls++;
}
static void offlinePlayback(void){
 Render state={0};void *raw=spice_zig_audio_playback_create(8000,2,renderPCM,&state);assert(raw);SZAudioDevice *device=(__bridge SZAudioDevice *)raw;
 AVAudioFormat *format=[[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:8000 channels:2 interleaved:NO];assert(format);
 NSError *error=nil;assert([device.engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:format maximumFrameCount:128 error:&error]);assert(!spice_zig_audio_playback_start(raw));
 AVAudioPCMBuffer *output=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:128];assert(output);
 AVAudioEngineManualRenderingStatus status=[device.engine renderOffline:128 toBuffer:output error:&error];assert(status==AVAudioEngineManualRenderingStatusSuccess);assert(state.calls>0&&output.frameLength==128);
 for(uint32_t channel=0;channel<2;channel++)for(uint32_t frame=0;frame<128;frame++)assert(fabsf(output.floatChannelData[channel][frame]-(float)((int)(frame*2+channel)-256)/32768.f)<1e-7f);
 spice_zig_audio_device_stop(raw);unsigned calls=state.calls;spice_zig_audio_device_stop(raw);spice_zig_audio_device_destroy(raw);assert(calls==state.calls);
}
int main(void){alarm(30);@autoreleasepool{
 offlinePlayback();
 for(unsigned run=0;run<32;run++){
  void *format=audio_probe_format(8000,2,0,1);assert(format);void *input=audio_probe_input(format,1024,run);assert(input);
  void *converter=spice_zig_audio_converter_create(format,8000,2,1024,1032);assert(converter);
  assert(spice_zig_audio_converter_matches(converter,input));SpiceZigAudioBuffer src,dst;assert(!spice_zig_audio_buffer_at(input,0,&src));
  void *chunk=spice_zig_audio_converter_input(converter,1024);assert(chunk);assert(!spice_zig_audio_buffer_at(chunk,0,&dst));assert(src.bytes==4096&&dst.bytes>=4096);memcpy(dst.data,src.data,4096);
  assert(!spice_zig_audio_convert(converter));void *output=spice_zig_audio_converter_output(converter);SpiceZigAudioBufferInfo info;assert(!spice_zig_audio_buffer_info(output,&info));assert(info.frames==1024&&info.buffers==1);assert(!spice_zig_audio_buffer_at(output,0,&dst));assert(!memcmp(src.data,dst.data,4096));
  spice_zig_audio_converter_destroy(converter);audio_probe_release(input);audio_probe_release(format);
  Context *c=calloc(1,sizeof(*c));assert(c);pthread_mutex_init(&c->mutex,NULL);pthread_cond_init(&c->changed,NULL);
  SZAudioGate *gate=[SZAudioGate new];gate->context=c;Work work={.gate=(__bridge void *)gate,.context=c};pthread_t worker,stop;
  assert(!pthread_create(&worker,NULL,callback,&work));pthread_mutex_lock(&c->mutex);while(!c->entered)pthread_cond_wait(&c->changed,&c->mutex);pthread_mutex_unlock(&c->mutex);
  assert(!pthread_create(&stop,NULL,closer,&work));while(!atomic_load(&work.closeStarted))sched_yield();assert(!atomic_load(&work.closeFinished));
  pthread_mutex_lock(&c->mutex);c->released=true;pthread_cond_broadcast(&c->changed);pthread_mutex_unlock(&c->mutex);pthread_join(worker,NULL);pthread_join(stop,NULL);assert(c->calls==1&&atomic_load(&work.closeFinished));
  pthread_cond_destroy(&c->changed);pthread_mutex_destroy(&c->mutex);free(c);
  // A queued native closure may still retain the gate after context teardown.
  assert(![gate enter]);[gate close];gate=nil;
 }
 puts("Offline AVAudioEngine exact PCM and 32 AVAudioConverter + joined callback context lifecycles passed (native ASan/UBSan)");
}return 0;}
