#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#include <pthread.h>
#include "audio_bridge.h"
int spice_zig_audio_format_info(void *raw,SpiceZigAudioFormat *out) {
    if(!raw||!out)return -1;AVAudioFormat *f=(__bridge AVAudioFormat *)raw;
    const AudioStreamBasicDescription *d=f.streamDescription;if(!d)return -1;
    *out=(SpiceZigAudioFormat){f.sampleRate,f.channelCount,d->mBytesPerFrame,f.interleaved,f.commonFormat};return 0;
}
int spice_zig_audio_buffer_info(void *raw,SpiceZigAudioBufferInfo *out) {
    if(!raw||!out)return -1;AVAudioPCMBuffer *b=(__bridge AVAudioPCMBuffer *)raw;
    *out=(SpiceZigAudioBufferInfo){b.frameLength,b.audioBufferList->mNumberBuffers};return 0;
}
uint32_t spice_zig_audio_list_count(void *raw){return raw?((AudioBufferList *)raw)->mNumberBuffers:0;}
int spice_zig_audio_list_at(void *raw,uint32_t index,SpiceZigAudioBuffer *out){
    if(!raw||!out)return -1;AudioBufferList *list=raw;if(index>=list->mNumberBuffers)return -1;
    AudioBuffer b=list->mBuffers[index];*out=(SpiceZigAudioBuffer){b.mData,b.mDataByteSize,b.mNumberChannels};return 0;
}
int spice_zig_audio_buffer_at(void *raw,uint32_t index,SpiceZigAudioBuffer *out){
    if(!raw)return -1;AVAudioPCMBuffer *b=(__bridge AVAudioPCMBuffer *)raw;
    return spice_zig_audio_list_at(b.mutableAudioBufferList,index,out);
}
@interface SZAudioProvider:NSObject
@property(nonatomic,strong) AVAudioPCMBuffer *offered;
@end
@implementation SZAudioProvider @end
@interface SZAudioConverter:NSObject
@property(nonatomic,strong) AVAudioConverter *converter;
@property(nonatomic,strong) AVAudioPCMBuffer *input,*output;
@property(nonatomic,strong) SZAudioProvider *provider;
@property(nonatomic,copy) AVAudioConverterInputBlock inputBlock;
@end
@implementation SZAudioConverter @end
void *spice_zig_audio_converter_create(void *input_format,uint32_t rate,uint32_t channels,uint32_t input_frames,uint32_t output_frames){
    if(!input_format||!rate||!channels||!input_frames||!output_frames)return NULL;
    AVAudioFormat *input=(__bridge AVAudioFormat *)input_format;
    AVAudioFormat *output=[[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:rate channels:channels interleaved:YES];if(!output)return NULL;
    SZAudioConverter *owner=[SZAudioConverter new];owner.converter=[[AVAudioConverter alloc] initFromFormat:input toFormat:output];if(!owner.converter)return NULL;
    owner.input=[[AVAudioPCMBuffer alloc] initWithPCMFormat:input frameCapacity:input_frames];
    owner.output=[[AVAudioPCMBuffer alloc] initWithPCMFormat:output frameCapacity:output_frames];if(!owner.input||!owner.output)return NULL;
    SZAudioProvider *provider=[SZAudioProvider new];owner.provider=provider;
    owner.inputBlock=^AVAudioBuffer *(AVAudioPacketCount packets,AVAudioConverterInputStatus *status){
        (void)packets;AVAudioPCMBuffer *buffer=provider.offered;provider.offered=nil;
        *status=buffer?AVAudioConverterInputStatus_HaveData:AVAudioConverterInputStatus_NoDataNow;return buffer;
    };
    return (__bridge_retained void *)owner;
}
void spice_zig_audio_converter_destroy(void *raw){if(raw)CFRelease(raw);}
int spice_zig_audio_converter_matches(void *raw,void *input){if(!raw||!input)return 0;SZAudioConverter *owner=(__bridge SZAudioConverter *)raw;return [((__bridge AVAudioPCMBuffer *)input).format isEqual:owner.converter.inputFormat];}
void *spice_zig_audio_converter_input(void *raw,uint32_t frames){if(!raw)return NULL;SZAudioConverter *owner=(__bridge SZAudioConverter *)raw;if(frames>owner.input.frameCapacity)return NULL;owner.input.frameLength=frames;return (__bridge void *)owner.input;}
void *spice_zig_audio_converter_output(void *raw){if(!raw)return NULL;return (__bridge void *)((__bridge SZAudioConverter *)raw).output;}
int spice_zig_audio_convert(void *raw){
    if(!raw)return -1;SZAudioConverter *owner=(__bridge SZAudioConverter *)raw;owner.output.frameLength=0;owner.provider.offered=owner.input;
    AVAudioConverterOutputStatus status=[owner.converter convertToBuffer:owner.output error:nil withInputFromBlock:owner.inputBlock];owner.provider.offered=nil;
    return status==AVAudioConverterOutputStatus_Error?-1:0;
}
/* The native closure retains this gate, never its engine owner. stop prevents
 * new borrows, joins in-flight calls, then detaches Apple nodes. Late closures
 * can run safely with a closed gate after the Zig context has been destroyed. */
@interface SZAudioGate:NSObject {
@public pthread_mutex_t mutex;pthread_cond_t changed;size_t active;BOOL closed;
void *context;SpiceZigAudioRender render;SpiceZigAudioCapture capture;
}
-(BOOL)enter;
-(void)leave;
-(void)close;
@end
@implementation SZAudioGate
-(instancetype)init { if((self=[super init])) {pthread_mutex_init(&mutex,NULL);pthread_cond_init(&changed,NULL);}return self; }
-(BOOL)enter {pthread_mutex_lock(&mutex);BOOL accepted=!closed;if(accepted)active++;pthread_mutex_unlock(&mutex);return accepted;}
-(void)leave {pthread_mutex_lock(&mutex);NSCAssert(active>0,@"unbalanced audio callback");active--;pthread_cond_broadcast(&changed);pthread_mutex_unlock(&mutex);}
-(void)close {pthread_mutex_lock(&mutex);closed=YES;while(active)pthread_cond_wait(&changed,&mutex);context=NULL;pthread_mutex_unlock(&mutex);}
-(void)dealloc {pthread_cond_destroy(&changed);pthread_mutex_destroy(&mutex);}
@end
@interface SZAudioDevice:NSObject
@property(nonatomic,strong) AVAudioEngine *engine;
@property(nonatomic,strong) AVAudioSourceNode *source;
@property(nonatomic,strong) AVAudioFormat *inputFormat;
@property(nonatomic,strong) SZAudioGate *gate;
@property(nonatomic) BOOL tapInstalled,stopped,started;
@end
@implementation SZAudioDevice @end
void *spice_zig_audio_playback_create(uint32_t rate,uint32_t channels,SpiceZigAudioRender render,void *context){
    if(!rate||!channels||!render||!context)return NULL;
    AVAudioFormat *format=[[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:rate channels:channels interleaved:YES];if(!format)return NULL;
    SZAudioDevice *owner=[SZAudioDevice new];owner.engine=[AVAudioEngine new];SZAudioGate *gate=[SZAudioGate new];owner.gate=gate;gate->context=context;gate->render=render;
    owner.source=[[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL *silence,const AudioTimeStamp *time,AVAudioFrameCount frames,AudioBufferList *list){
        (void)time;
        if([gate enter]){gate->render(gate->context,frames,list);[gate leave];}
        else { for(UInt32 i=0;i<list->mNumberBuffers;i++)if(list->mBuffers[i].mData)memset(list->mBuffers[i].mData,0,list->mBuffers[i].mDataByteSize);if(silence)*silence=YES; }
        return noErr;
    }];
    if(!owner.source)return NULL;[owner.engine attachNode:owner.source];[owner.engine connect:owner.source to:owner.engine.mainMixerNode format:format];return (__bridge_retained void *)owner;
}
int spice_zig_audio_playback_start(void *raw){if(!raw)return -1;SZAudioDevice *owner=(__bridge SZAudioDevice *)raw;if(owner.stopped||owner.started||!owner.source)return -1;[owner.engine prepare];if(![owner.engine startAndReturnError:nil])return -1;owner.started=YES;return 0;}
void spice_zig_audio_playback_gain(void *raw,float gain){if(raw)((__bridge SZAudioDevice *)raw).engine.mainMixerNode.outputVolume=gain;}
void *spice_zig_audio_capture_create(SpiceZigAudioCapture capture,void *context){
    if(!capture||!context)return NULL;SZAudioDevice *owner=[SZAudioDevice new];owner.engine=[AVAudioEngine new];owner.gate=[SZAudioGate new];owner.gate->context=context;owner.gate->capture=capture;
    owner.inputFormat=[owner.engine.inputNode outputFormatForBus:0];if(!owner.inputFormat||owner.inputFormat.sampleRate<=0||!owner.inputFormat.channelCount)return NULL;return (__bridge_retained void *)owner;
}
void *spice_zig_audio_capture_format(void *raw){return raw?(__bridge void *)((__bridge SZAudioDevice *)raw).inputFormat:NULL;}
int spice_zig_audio_capture_start(void *raw){
    if(!raw)return -1;SZAudioDevice *owner=(__bridge SZAudioDevice *)raw;if(owner.stopped||owner.started||owner.source||!owner.inputFormat)return -1;
    SZAudioGate *gate=owner.gate;
    [owner.engine.inputNode installTapOnBus:0 bufferSize:1024 format:owner.inputFormat block:^(AVAudioPCMBuffer *buffer,AVAudioTime *time){(void)time;if([gate enter]){gate->capture(gate->context,(__bridge void *)buffer);[gate leave];}}];owner.tapInstalled=YES;
    [owner.engine prepare];if(![owner.engine startAndReturnError:nil]){[owner.engine.inputNode removeTapOnBus:0];owner.tapInstalled=NO;return -1;}owner.started=YES;return 0;
}
void spice_zig_audio_device_stop(void *raw){
    if(!raw)return;SZAudioDevice *owner=(__bridge SZAudioDevice *)raw;if(owner.stopped)return;owner.stopped=YES;[owner.gate close];
    if(owner.tapInstalled){[owner.engine.inputNode removeTapOnBus:0];owner.tapInstalled=NO;}[owner.engine stop];
    if(owner.source){[owner.engine disconnectNodeOutput:owner.source];[owner.engine detachNode:owner.source];owner.source=nil;}
}
void spice_zig_audio_device_destroy(void *raw){if(raw){spice_zig_audio_device_stop(raw);CFRelease(raw);}}
