#ifndef SPICE_ZIG_DIAGNOSTICS_H
#define SPICE_ZIG_DIAGNOSTICS_H
#include "spice_zig_source.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Diagnostics retains Source independently of the adapter/Desktop. Captures
 * retain their registry independently. Join external calls before destruction.
 * Capture does not create/write a file until explicit finish. Only one capture
 * per Source may be active. Host stages must use spice_zig_diagnostics_now_ns.
 * Actual drawable presentation, NOT GPU completion, supplies presented stage.
 * Error -2 allocation, -31 cancellation, -61 capture finished, -62 busy,
 * -63 record/file bound, -1 other; error_category is a static fixed string.
 */
typedef struct SpiceZigDiagnostics SpiceZigDiagnostics;
typedef struct SpiceZigTraceCapture SpiceZigTraceCapture;
typedef struct SpiceZigTraceRecord SpiceZigTraceRecord;
int spice_zig_source_diagnostics(SpiceZigSource *,SpiceZigDiagnostics **);
void spice_zig_diagnostics_destroy(SpiceZigDiagnostics *);
uint64_t spice_zig_diagnostics_now_ns(void);
uint64_t spice_zig_diagnostics_epoch(SpiceZigDiagnostics *);
void spice_zig_diagnostics_reset(SpiceZigDiagnostics *);
typedef struct {uint64_t count;double p95_ms,maximum_ms;uint32_t has_values,reserved;} SpiceZigTimingSummary;
enum {SPICE_ZIG_METAL_PRESENTED,SPICE_ZIG_ADVANCED_PRESENTED,SPICE_ZIG_METAL_ERRORS,SPICE_ZIG_SUPERSEDED,SPICE_ZIG_DRAWABLE_MISSES,SPICE_ZIG_COMMAND_CREATION_FAILURES,SPICE_ZIG_COMMANDS_COMMITTED,SPICE_ZIG_TEXTURE_HITS,SPICE_ZIG_TEXTURE_MISSES,SPICE_ZIG_TEXTURE_EVICTIONS,SPICE_ZIG_GPU_BUSY,SPICE_ZIG_LINK_WAKEUPS,SPICE_ZIG_LINK_TICKS,SPICE_ZIG_LINK_IDLE,SPICE_ZIG_IMMEDIATE_SELECTIONS};
enum {SPICE_ZIG_READY_TO_SELECTION,SPICE_ZIG_UPDATE_TO_COMMIT,SPICE_ZIG_COMMIT_TO_COMPLETION,SPICE_ZIG_REQUEST_TO_PRESENTED};
enum {SPICE_ZIG_NO_METAL,SPICE_ZIG_NO_IOSURFACE,SPICE_ZIG_DIMENSION_MISMATCH,SPICE_ZIG_FORMAT_MISMATCH,SPICE_ZIG_TEXTURE_FAILED,SPICE_ZIG_COMMAND_FAILED};
typedef struct {uint64_t counters[15];SpiceZigTimingSummary latency[4];uint64_t fallback_frames,fallback_counts[6];uint32_t last_fallback,has_fallback;} SpiceZigPresentationMetrics;
int spice_zig_diagnostics_metrics(SpiceZigDiagnostics *,SpiceZigPresentationMetrics *);
int spice_zig_diagnostics_count(SpiceZigDiagnostics *,uint32_t counter,uint64_t count,const uint64_t *epoch);
int spice_zig_diagnostics_presented(SpiceZigDiagnostics *,uint8_t advanced,const uint64_t *epoch);
int spice_zig_diagnostics_interval(SpiceZigDiagnostics *,uint32_t kind,uint64_t start,uint64_t end,const uint64_t *epoch);
int spice_zig_diagnostics_fallback(SpiceZigDiagnostics *,uint32_t reason);
typedef struct {uint64_t desktop_generation,surface_generation,frame_revision,delivery_sequence;uint32_t surface_id;uint8_t channel_id,reserved[3];} SpiceZigTraceIdentity;
/* 1 frame identity, 0 no frame, negative error. Identity uses original frame
 * sequence even on cursor-only snapshots and authoritative redraws. */
int spice_zig_snapshot_trace_identity(const SpiceZigSnapshot *,SpiceZigTraceIdentity *);
enum {SPICE_ZIG_TRACE_SELECTED,SPICE_ZIG_TRACE_COMMITTED,SPICE_ZIG_TRACE_PRESENTED,SPICE_ZIG_TRACE_DROPPED};
int spice_zig_diagnostics_trace_stage(SpiceZigDiagnostics *,uint32_t stage,const SpiceZigTraceIdentity *,uint64_t time_ns,uint64_t ready_ns);
typedef struct {const uint8_t *data;size_t size;} SpiceZigTraceString;
typedef struct {SpiceZigTraceString pair_id,version,run_id,token,path;uint64_t order;uint32_t action,checksum;} SpiceZigTraceConfig; /* action 0 click, 1 key, 2 motion */
int spice_zig_trace_create(SpiceZigDiagnostics *,const SpiceZigTraceConfig *,SpiceZigTraceCapture **,const char **error_category);
void spice_zig_trace_destroy(SpiceZigTraceCapture *);
int spice_zig_trace_host_input(SpiceZigTraceCapture *,uint64_t scheduled,uint64_t input,uint64_t send_started);
int spice_zig_trace_send_completed(SpiceZigTraceCapture *,uint64_t time_ns,const uint64_t *motion_ack);
int spice_zig_trace_motion_ack(SpiceZigTraceCapture *,uint64_t time_ns);
int spice_zig_trace_guest(SpiceZigTraceCapture *,uint64_t received,uint64_t drawn,uint64_t marker_revision);
/* Blocking; token cancellation wakes the exact wait. Reuse after cancelled wait
 * is permitted. Finish wakes unfinished waiters. Join waits before destroy. */
int spice_zig_trace_wait(SpiceZigTraceCapture *,SpiceZigDesktopSendToken *,SpiceZigTraceIdentity *);
/* reason.data=NULL,size=0 means no external reason. Failed append freezes the
 * record and may be retried; reason on retries is ignored. Successful finish
 * detaches and returns independently owned canonical JSON without newline. */
int spice_zig_trace_finish(SpiceZigTraceCapture *,SpiceZigTraceString reason,SpiceZigTraceRecord **,const char **error_category);
int spice_zig_trace_record_bytes(const SpiceZigTraceRecord *,const uint8_t **,size_t *);
void spice_zig_trace_record_destroy(SpiceZigTraceRecord *);
#ifdef __cplusplus
}
#endif
#endif
