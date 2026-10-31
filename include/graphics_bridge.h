#ifndef SPICE_ZIG_GRAPHICS_BRIDGE_H
#define SPICE_ZIG_GRAPHICS_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
// Retained handles. Frames keep their own native resources alive independently
// of the creating context. Every submitted command completes before return.
void *spice_zig_graphics_create(const char *metallib_path);
void spice_zig_graphics_retain(void *context);
void spice_zig_graphics_destroy(void *context);
uint64_t spice_zig_graphics_submitted(void *context);
int spice_zig_graphics_frame_layout(uint32_t width, uint32_t height, size_t *stride, size_t *size);
size_t spice_zig_graphics_frame_size(void *frame);
void *spice_zig_graphics_frame_create(void *context, uint32_t width, uint32_t height);
void spice_zig_graphics_frame_destroy(void *frame);
int spice_zig_graphics_frame_lock(void *frame, int writing, uint8_t **bytes, size_t *stride, size_t *size);
int spice_zig_graphics_frame_unlock(void *frame, int writing);
void *spice_zig_graphics_frame_texture(void *frame); // Borrowed until frame release.
void *spice_zig_graphics_frame_surface(void *frame); // Borrowed IOSurfaceRef.
int spice_zig_graphics_copy(void *context, void *source, void *destination);
// Uniform layout is identical to the existing SpiceVideoCompositor.metal.
// rects: source x/y/w/h, destination x/y/w/h, clip x/y/w/h.
int spice_zig_graphics_compose_bgra(void *context, void *source, void *destination,
                                  const uint32_t rects[12], int flip);
int spice_zig_graphics_lanczos(void *context, void *source, void *destination);
int spice_zig_graphics_compose_video(void *context, void *pixel_buffer, void *destination, const uint32_t uniforms[32]);
// Host invokes submit inside its drawable acquisition/draw callback. Success
// schedules exactly one GPU completion; failure schedules none. No screen
// presentation timestamp is inferred from GPU completion.
void *spice_zig_presenter_create(void *context, const char *presentation_metallib);
void spice_zig_presenter_destroy(void *presenter);
int spice_zig_presenter_submit(void *presenter, void *source_frame, void *destination_texture,
                               void *optional_drawable, uint32_t width, uint32_t height,
                               int lanczos, void (*completion)(void *, int), void *user);
// Optional observations are delivered asynchronously on the main queue. Submit
// with an observer MUST run on the main thread. The descriptor is copied and its
// context retained until all native/queued blocks release it (possibly after GPU
// completion or presenter destruction). retain/release must be thread-safe.
// stage 1: command completed, status 0 success/-1 failure; stage 2: drawable
// callback, status 0 presented/-1 dropped. media_time is CA presentedTime (zero
// on drop), media_now and continuous_ns are sampled at callback for calibration.
// No presentation event is synthesized when there is no drawable.
typedef struct {
    uint32_t stage; int32_t status;
    uint64_t continuous_ns;
    double media_time,media_now;
} SpiceZigNativePresentationEvent;
typedef struct {
    void *context;
    void (*retain)(void *);
    void (*release)(void *);
    void (*event)(void *,const SpiceZigNativePresentationEvent *);
} SpiceZigNativePresentationObserver;
int spice_zig_presenter_submit_observed(void *presenter,void *source_frame,void *destination_texture,
    void *optional_drawable,uint32_t width,uint32_t height,int lanczos,
    void (*completion)(void *,int),void *user,
    const SpiceZigNativePresentationObserver *observer,uint64_t *commit_ns);
void spice_zig_graphics_memory(void *graphics, uint64_t *recommended, uint64_t *allocated);
#endif
