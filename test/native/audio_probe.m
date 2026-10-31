#import <AVFAudio/AVFAudio.h>
#include <stdint.h>
#include <stddef.h>
void *audio_probe_format(uint32_t rate,uint32_t channels,uint32_t floating,uint32_t interleaved){
    AVAudioFormat *format=[[AVAudioFormat alloc] initWithCommonFormat:floating?AVAudioPCMFormatFloat32:AVAudioPCMFormatInt16 sampleRate:rate channels:channels interleaved:interleaved!=0];return (__bridge_retained void *)format;
}
void *audio_probe_input(void *raw,uint32_t frames,uint32_t seed){
    AVAudioFormat *format=(__bridge AVAudioFormat *)raw;AVAudioPCMBuffer *buffer=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:MAX(frames,1)];if(!buffer)return NULL;buffer.frameLength=frames;
    AudioBufferList *list=buffer.mutableAudioBufferList;
    for(uint32_t bank=0;bank<list->mNumberBuffers;bank++){
        uint32_t samples=frames*(format.interleaved?format.channelCount:1);
        for(uint32_t i=0;i<samples;i++){
            int16_t sample=(int16_t)((i*47u+bank*123u+seed*17u)%16384u-8192);
            if(format.commonFormat==AVAudioPCMFormatFloat32)((float *)list->mBuffers[bank].mData)[i]=(float)sample/32768.f;
            else ((int16_t *)list->mBuffers[bank].mData)[i]=sample;
        }
    }return (__bridge_retained void *)buffer;
}
void audio_probe_release(void *raw){if(raw)CFRelease(raw);}
void audio_probe_shorten(void *raw){AVAudioPCMBuffer *b=(__bridge AVAudioPCMBuffer *)raw;b.mutableAudioBufferList->mBuffers[0].mDataByteSize=1;}
void *audio_probe_list(void *raw){return ((__bridge AVAudioPCMBuffer *)raw).mutableAudioBufferList;}
