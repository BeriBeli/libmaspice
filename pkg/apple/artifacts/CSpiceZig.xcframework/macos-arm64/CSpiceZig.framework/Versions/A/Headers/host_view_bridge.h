#ifndef SPICE_ZIG_HOST_VIEW_BRIDGE_H
#define SPICE_ZIG_HOST_VIEW_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
typedef struct { double x,y; } SZHostPoint;
typedef struct { double x,y,width,height; } SZHostRect;
// Private main-thread AppKit edge. box holds a weak view, never a retained view.
void sz_host_box_destroy(void *);
void sz_host_schedule(void *,void *controller);
void sz_host_ticking(void *,int);
void sz_host_layout(void *,SZHostRect,double,double);
int sz_host_draw(void *,void *controller);
void sz_host_content(void *,int);
void sz_host_cursor(void *,int,const uint8_t *,size_t,uint16_t,uint16_t,SZHostPoint,SZHostPoint,const SZHostRect *);
void sz_host_input(void *,uint8_t,int32_t,int32_t,uint8_t);
void sz_host_failure(void *,const char *);
int sz_host_location(void *,SZHostPoint *);
int sz_host_disconnect(void *);
void sz_host_warp(void *,SZHostPoint);
void sz_host_reconnect(void *);
void sz_host_hide(void *);
void sz_host_unhide(void *);
void sz_host_cpu_pixels(void *cg,const uint8_t *,size_t,uint32_t,uint32_t,int,SZHostRect);
// Consumes one Source reference returned by source_acquire, creates a controller
// that owns box on success. Native context is borrowed during construction.
void *spice_zig_host_controller_create(void *session,void *box,uint8_t,uint32_t,const char *);
void spice_zig_host_close(void *);
void spice_zig_host_release(void *);
void spice_zig_host_ready(void *);
void spice_zig_host_tick(void *);
void spice_zig_host_configure(void *,int,SZHostRect,double);
int spice_zig_host_submit(void *,void *texture,void *drawable,uint32_t,uint32_t);
void spice_zig_host_cpu_draw(void *,void *cg);
int spice_zig_host_key(void *,int,uint16_t,uint64_t,int);
void spice_zig_host_flags(void *,uint16_t,uint64_t);
void spice_zig_host_focus_lost(void *);
void spice_zig_host_button(void *,int,int64_t,int);
void spice_zig_host_motion(void *,SZHostPoint,double,double);
void spice_zig_host_scroll(void *,double);
// Internal cross-archive Source boundary. Borrow Session only during call.
void *spice_zig_source_acquire_core(void *session);
void *spice_zig_source_native_context(void *session);
void *spice_zig_graphics_device(void *context); // Borrowed.
#endif
