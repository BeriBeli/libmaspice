#ifndef SPICE_ZIG_HOST_VIEW_H
#define SPICE_ZIG_HOST_VIEW_H
#include "spice_zig_source.h"
#ifdef __cplusplus
extern "C" {
#endif
// Optional AppKit library, main thread only. Returned retained NSView* is ARC
// bridge-transfer compatible. close is idempotent; release releases this C owner.
// NSView deallocation also closes. Removing it from a window stops demand/capture.
// Input callbacks must enqueue outgoing work, never block on network I/O. They
// may close/release the view. Context retain/release are balanced by the host and
// queued observations; release can occur on a worker thread after view teardown.
// Input kind/x/y/display use spice_zig_desktop_input's encoding. Library stores
// only fixed error category names; last_error is borrowed until next failure.
typedef struct {
    void *context;
    void (*retain)(void *);
    void (*release)(void *);
    void (*input)(void *,uint8_t kind,int32_t x,int32_t y,uint8_t display);
} SpiceZigHostInput;
void *spice_zig_host_view_create(SpiceZigSource *,uint8_t channel,uint32_t surface,
    const char *presentation_metallib,const SpiceZigHostInput *);
void spice_zig_host_view_close(void *nsview);
void spice_zig_host_view_release(void *nsview);
const char *spice_zig_host_view_last_error(void *nsview);
#ifdef __cplusplus
}
#endif
#endif
