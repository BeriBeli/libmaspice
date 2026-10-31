#ifndef SPICE_ZIG_AUDIO_H
#define SPICE_ZIG_AUDIO_H
#include "spice_zig_desktop.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Optional joined audio executor. All methods thread-safe except destroy, which
 * requires joined callers. Feed Desktop events in their receive order; observe
 * borrows the event and retains only relevant PCM. Destroy BEFORE Desktop.
 * Device access is opt-in: defaults are both disabled, and enabled devices open
 * only on corresponding START events. The app supplies microphone usage/consent.
 * One executor owns the selected Record stream; do not independently send its
 * MODE/START_MARK/PCM. Logical guest and START epochs fence old capture data.
 * Stop cancels pending writes; an uncertain partial write closes the exact
 * Record transport to preserve framing. Idle cancellation does not close it.
 * 64 observations/maximum_event_bytes bound PCM retention; overflow is terminal
 * -48. Notification queue keeps newest32 (same as existing Swift sinks).
 * No system device or microphone is opened by default options. */
typedef struct SpiceZigAudio SpiceZigAudio;
typedef struct {
    uint8_t playback,capture,playback_id,record_id;
    uint32_t maximum_queued_ms,delay_interval_ms,reserved;
    size_t maximum_event_bytes;
} SpiceZigAudioOptions;
void spice_zig_audio_options(SpiceZigAudioOptions *);
int spice_zig_audio_create(SpiceZigDesktop *,const SpiceZigAudioOptions *,SpiceZigAudio **out);
int spice_zig_audio_observe(SpiceZigAudio *,const SpiceZigDesktopEvent *);
void spice_zig_audio_stop(SpiceZigAudio *);
/* Owner-only: stops and joins; no simultaneous join/destroy caller. Statistics
 * and notifications remain available. Detach from routes before calling. */
void spice_zig_audio_join(SpiceZigAudio *);
void spice_zig_audio_destroy(SpiceZigAudio *);
/* status0 running,1 joined work finished,negative terminal failure. */
int spice_zig_audio_status(SpiceZigAudio *);
typedef struct {
    uint64_t scheduled_packets,scheduled_frames,queued_playback_bytes;
    uint64_t queued_capture_bytes,underflows,notifications_dropped;
} SpiceZigAudioStatistics;
int spice_zig_audio_statistics(SpiceZigAudio *,SpiceZigAudioStatistics *);
typedef struct {
    uint32_t kind,recording,channels,frequency,milliseconds,muted,volume_count,reserved;
    uint16_t volume[32];uint64_t count;const char *error_category;
} SpiceZigAudioEvent;
/* next1 event,0 empty,negative invalid argument. Caller-owned fixed value.
 * kind1 started (channels/frequency),2 stopped,3 mute,4 Record volume,
 * 5 overflow,6 oversized (milliseconds),7 underrun(count),8 failed.
 * Error strings are static content-free categories, valid after destroy.
 * Statistics and event records do not retain PCM or Apple resources. */
int spice_zig_audio_next(SpiceZigAudio *,SpiceZigAudioEvent *);
/* Optional late-attachment adapter, one channel-zero sink per direction.
 * Feed ordered Desktop events, once each. Retains at most 32 events/32MiB per
 * unattached direction (newest replay cache; public stream overflow is separate). Terminal and
 * new-guest events clear retained history. Attach atomically replays backlog.
 * Borrowed runners MUST remain alive until detach returns; detach joins observe.
 * Join all callers and detach every runner before destroying the route. */
typedef struct SpiceZigAudioRoute SpiceZigAudioRoute;
int spice_zig_audio_route_create(SpiceZigAudioRoute **);
void spice_zig_audio_route_destroy(SpiceZigAudioRoute *);
int spice_zig_audio_route_observe(SpiceZigAudioRoute *,const SpiceZigDesktopEvent *);
int spice_zig_audio_route_attach(SpiceZigAudioRoute *,uint8_t recording,SpiceZigAudio *);
void spice_zig_audio_route_detach(SpiceZigAudioRoute *,uint8_t recording,SpiceZigAudio *);
#ifdef __cplusplus
}
#endif
#endif
