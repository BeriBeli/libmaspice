#ifndef SPICE_ZIG_SOURCE_H
#define SPICE_ZIG_SOURCE_H
#include "spice_zig_desktop.h"
#ifdef __cplusplus
extern "C" {
#endif
/* One source adapter borrows Desktop. Feed every ordered event from its sole
 * event-reader, before destroying that event. Destroy adapter BEFORE Desktop;
 * join observe calls first. Independent subscriptions retain source state and
 * survive adapter/Desktop destruction. No raw set_demand/ack calls when this
 * source owns those channels. status exposes terminal allocation/resource errors.
 * 0 success, -2 allocation, -60 configured resource bound, -1 other failure.
 * Canonical frame byte budget excludes independently retained consumer snapshots.
 */
typedef struct SpiceZigSource SpiceZigSource;
/* Local offline rendering: serialize Store calls and destroy after callers join.
 * Snapshots remain immutable and usable after Store destruction. Synthetic Source
 * calls must not run concurrently with observe or a live session binding. */
typedef struct SpiceZigOffscreen SpiceZigOffscreen;
int spice_zig_offscreen_create(SpiceZigOffscreen **);
void spice_zig_offscreen_destroy(SpiceZigOffscreen *);
int spice_zig_offscreen_surface(SpiceZigOffscreen *,uint32_t id,uint32_t width,uint32_t height,uint32_t format);
int spice_zig_offscreen_fill(SpiceZigOffscreen *,uint32_t id,const SpiceZigDamageRect *,uint32_t argb);
int spice_zig_offscreen_frame(SpiceZigOffscreen *,uint32_t id,SpiceZigFrame **);
int spice_zig_source_begin_synthetic(SpiceZigSource *);
int spice_zig_source_publish_synthetic(SpiceZigSource *,const SpiceZigFrame *);

typedef struct SpiceZigSubscription SpiceZigSubscription;
typedef struct SpiceZigSnapshot SpiceZigSnapshot;
typedef struct SpiceZigReady SpiceZigReady;
typedef struct {size_t maximum_subscriptions,maximum_surfaces,maximum_frame_bytes;} SpiceZigSourceOptions;
void spice_zig_source_options(SpiceZigSourceOptions *);
int spice_zig_source_create(SpiceZigDesktop *,const SpiceZigSourceOptions *,SpiceZigSource **);
void spice_zig_source_destroy(SpiceZigSource *);
int spice_zig_source_observe(SpiceZigSource *,const SpiceZigDesktopEvent *);
int spice_zig_source_status(SpiceZigSource *,const char **error_category);
typedef struct {uint64_t delivered,coalesced,handler_deliveries,subscriptions,visible;} SpiceZigSourceMetrics;
int spice_zig_source_metrics(SpiceZigSource *,SpiceZigSourceMetrics *);
int spice_zig_source_subscribe(SpiceZigSource *,uint8_t channel,uint32_t surface,SpiceZigSubscription **);
/* All operations except destroy are safe concurrently. cancel is idempotent
 * and wakes next(wait=1). Join external next/method callers before destroy.
 * Visibility starts false. A stream auto-ACKs only when all visible subscribers
 * for its Surface are streams; a handler requires explicit acknowledge.
 */
void spice_zig_subscription_cancel(SpiceZigSubscription *);
void spice_zig_subscription_destroy(SpiceZigSubscription *);
int spice_zig_subscription_demand(SpiceZigSubscription *,uint8_t visible);
int spice_zig_subscription_request_latest(SpiceZigSubscription *);
int spice_zig_subscription_acknowledge(SpiceZigSubscription *,uint64_t frame_session,uint8_t channel,uint32_t surface,uint64_t lifecycle,uint64_t revision);
/* 1 owned snapshot, 0 empty/cancelled, negative failure. Allocation failure
 * does not consume pending state. wait=0 polls, wait=1 blocks until update/cancel.
 * A handler receives borrowed snapshots outside Source's lock. retain/release
 * keep its context alive across captured deliveries, including cancellation.
 * emit may call subscription methods; it must not destroy the source adapter.
 * Switching to a handler discards pending stream data. NULL clears handler.
 */
int spice_zig_subscription_next(SpiceZigSubscription *,uint8_t wait,SpiceZigSnapshot **);
typedef struct {
    void *context;
    void (*retain)(void *);
    void (*release)(void *);
    void (*emit)(void *,const SpiceZigSnapshot *);
} SpiceZigSourceHandler;
int spice_zig_subscription_handler(SpiceZigSubscription *,const SpiceZigSourceHandler *);
int spice_zig_snapshot_clone(const SpiceZigSnapshot *,SpiceZigSnapshot **);
void spice_zig_snapshot_destroy(SpiceZigSnapshot *);
typedef struct {
    uint64_t generation,delivery_sequence,frame_sequence,frame_session;
    uint32_t pointer_mode,has_frame;
    uint8_t channel_id,reserved[7];
} SpiceZigSnapshotInfo;
/* pointer_mode: 0 absolute, 1 relative. frame_session fences guest switches;
 * Surface lifecycle/revision and exact damage come from extracted Frame. */
int spice_zig_snapshot_info(const SpiceZigSnapshot *,SpiceZigSnapshotInfo *);
/* 1 independent owned frame, 0 no frame. CPU pixels remain lazy. */
int spice_zig_snapshot_frame(const SpiceZigSnapshot *,SpiceZigFrame **);
typedef struct {
    int32_t x,y;
    uint32_t visible,trail_length,trail_frequency,has_image;
    uint64_t unique;
    uint32_t format,width,height,hot_x,hot_y,flags;
} SpiceZigSnapshotCursor;
/* 1 cursor state, 0 absent; pixel bytes borrowed until snapshot destruction. */
int spice_zig_snapshot_cursor(const SpiceZigSnapshot *,SpiceZigSnapshotCursor *,const uint8_t **bytes,size_t *count);
/* Thread-safe latest-ready latch. Offers borrow snapshots and merge damage.
 * 1 empty->ready, 0 coalesced/stale. take returns 1 owned snapshot or 0 empty.
 * Restore only fills an empty slot with a non-stale snapshot. Times are from
 * one caller-selected monotonic nanosecond clock; wait=max(0,selected-ready).
 * discard preserves the watermark. Destroy after callers join.
 */
SpiceZigReady *spice_zig_ready_create(void);
void spice_zig_ready_destroy(SpiceZigReady *);
int spice_zig_ready_offer(SpiceZigReady *,const SpiceZigSnapshot *,uint64_t ready_ns);
int spice_zig_ready_take(SpiceZigReady *,uint64_t selected_ns,SpiceZigSnapshot **,uint64_t *ready_ns,uint64_t *waiting_ns);
int spice_zig_ready_restore(SpiceZigReady *,const SpiceZigSnapshot *,uint64_t ready_ns);
void spice_zig_ready_discard(SpiceZigReady *);
#ifdef __cplusplus
}
#endif
#endif
