#ifndef SPICE_ZIG_VIDEO_BRIDGE_H
#define SPICE_ZIG_VIDEO_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
// Native object calls only; Zig owns parameters, policy and conversion. All
// returned references are +1; output pixel buffers survive session destruction.
int32_t spice_zig_video_format(int hevc, const uint8_t *const *sets, const size_t *sizes, size_t count, void **output);
void spice_zig_video_format_release(void *format);
void spice_zig_video_format_size(void *format, int32_t *width, int32_t *height);
int32_t spice_zig_video_session(void *format, void **output);
int32_t spice_zig_video_realtime(void *session);
int32_t spice_zig_video_hardware(void *session, int *hardware);
void spice_zig_video_session_release(void *session);
// Takes ownership of owner on EVERY path, exactly one release. No AVCC copy.
int32_t spice_zig_video_decode(void *session, void *format, const uint8_t *bytes, size_t size, uint32_t time,
                             void *owner, void (*release)(void *), void **pixel);
void spice_zig_video_frame_release(void *pixel);
void spice_zig_video_frame_retain(void *pixel);
// metadata: width,height,format (1 BGRA,2 NV12,0 other),matrix(601,709,0),range(1 full,2 video,0).
int spice_zig_video_metadata(void *pixel, uint32_t metadata[5]);
int spice_zig_video_lock(void *pixel);
int spice_zig_video_unlock(void *pixel);
int spice_zig_video_plane(void *pixel, size_t plane, const uint8_t **base, size_t *width, size_t *height, size_t *stride);
#endif
