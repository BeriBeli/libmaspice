#ifndef SPICE_ZIG_AUDIO_BRIDGE_H
#define SPICE_ZIG_AUDIO_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
/* Apple objects are opaque retained owners. Buffer/format getters borrow their
 * owner. Conversion has one serial caller; device stop joins callbacks before
 * the borrowed Zig context can be destroyed. No callback may stop itself. */
typedef struct { double sample_rate; uint32_t channels,bytes_per_frame,interleaved,common_format; } SpiceZigAudioFormat;
typedef struct { uint32_t frames,buffers; } SpiceZigAudioBufferInfo;
typedef struct { void *data; uint32_t bytes,channels; } SpiceZigAudioBuffer;
int spice_zig_audio_format_info(void *,SpiceZigAudioFormat *);
int spice_zig_audio_buffer_info(void *,SpiceZigAudioBufferInfo *);
int spice_zig_audio_buffer_at(void *,uint32_t,SpiceZigAudioBuffer *);
void *spice_zig_audio_converter_create(void *input_format,uint32_t output_rate,uint32_t output_channels,uint32_t input_frames,uint32_t output_frames);
void spice_zig_audio_converter_destroy(void *);
int spice_zig_audio_converter_matches(void *,void *input_buffer);
void *spice_zig_audio_converter_input(void *,uint32_t frames);
void *spice_zig_audio_converter_output(void *);
int spice_zig_audio_convert(void *);
typedef void (*SpiceZigAudioRender)(void *,uint32_t,void *audio_buffer_list);
typedef void (*SpiceZigAudioCapture)(void *,void *pcm_buffer);
void *spice_zig_audio_playback_create(uint32_t rate,uint32_t channels,SpiceZigAudioRender,void *context);
int spice_zig_audio_playback_start(void *);
void spice_zig_audio_playback_gain(void *,float);
/* Input device access is explicit. Create may touch AVAudioEngine.inputNode.
 * Apps own microphone usage declarations and consent UI. */
void *spice_zig_audio_capture_create(SpiceZigAudioCapture,void *context);
void *spice_zig_audio_capture_format(void *);
int spice_zig_audio_capture_start(void *);
void spice_zig_audio_device_stop(void *);
void spice_zig_audio_device_destroy(void *);
uint32_t spice_zig_audio_list_count(void *);
int spice_zig_audio_list_at(void *,uint32_t,SpiceZigAudioBuffer *);
#endif
