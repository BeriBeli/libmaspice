#ifndef SPICE_ZIG_PASTEBOARD_BRIDGE_H
#define SPICE_ZIG_PASTEBOARD_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
/* Apple main-queue/object adaptation. Policy and wait/cancel ownership are Zig.
 * Completion transfers an owned result (or NULL on error) exactly once. begin
 * may complete inline on main. NULL begin means no callback and out_status set.
 * Queued cancellation completes immediately; running AppKit work must finish.
 * A context retains at most one queued block until main has drained it. */
typedef void (*SpiceZigPasteboardComplete)(void *,int,void *);
void *spice_zig_pb_create(const uint8_t *name,size_t size,int general);
void spice_zig_pb_retain(void *);
void spice_zig_pb_destroy(void *);
int spice_zig_pb_pending(void *);
void *spice_zig_pb_begin(void *,int writing,const uint8_t *text,size_t size,size_t maximum,SpiceZigPasteboardComplete,void *,int *out_status);
void spice_zig_pb_cancel(void *);
void spice_zig_pb_operation_destroy(void *);
typedef struct {int64_t change_count;size_t size;uint32_t present,oversized;} SpiceZigPasteboardInfo;
int spice_zig_pb_result_info(void *,SpiceZigPasteboardInfo *);
const uint8_t *spice_zig_pb_result_bytes(void *);
void spice_zig_pb_result_destroy(void *);
#endif
