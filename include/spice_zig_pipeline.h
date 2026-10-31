#ifndef SPICE_ZIG_PIPELINE_H
#define SPICE_ZIG_PIPELINE_H
#include "spice_zig_desktop.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Best-effort non-atomic snapshot. Counters include adopted active/retired
 * Display channels; failed/preparing targets are excluded. Semi/seamless
 * migration retains the same counters. Counters reset on desktop_reset before the next connect.
 * Channel gauges are current samples plus the maximum/sum of last retirement
 * samples, following their documented aggregation. They are not live totals.
 * Only surface_bytes (active World), maximum_surface_bytes (configured limit),
 * and process_native_allocated_bytes (all default contexts) are live state.
 * Decoder statistics publish on render completion, including failures.
 * first_disable_reason: 0 absent, 1 MetalUnavailable, 2 GPUFailed.
 * Publications own their readback recorder after channel destruction, but later
 * changes to retired recorders are not retroactively added to session samples.
 * partial_copy_bytes is zero: current transactional CPU candidates copy full
 * frames. No unperformed legacy texture-cache or buffer-pool events are invented.
 * All timestamps are bounded histograms; no payload or per-frame log is exposed.
 */
typedef struct { uint64_t count; double p95_ms,maximum_ms; uint32_t has_values,reserved; } SpiceZigPipelineTiming;
typedef struct {
    uint64_t display_channels;
    uint64_t damage_operations;
    uint64_t damage_bytes;
    uint64_t snapshots;
    uint64_t full_copy_bytes;
    uint64_t partial_copy_bytes;
    uint64_t direct_native_write_bytes;
    uint64_t cpu_materializations;
    uint64_t cpu_materialization_bytes;
    uint64_t pool_exhaustions;
    uint64_t in_flight_publications;
    uint64_t pool_in_use;
    uint64_t native_enabled;
    uint64_t allocated_frames;
    uint64_t allocated_bytes;
    uint64_t process_native_allocated_bytes;
    uint64_t gpu_copy_bytes;
    uint64_t gpu_errors;
    uint64_t native_video_frames;
    uint64_t recommended_working_set;
    uint64_t metal_allocated_bytes;
    uint64_t surface_bytes;
    uint64_t maximum_surface_bytes;
    uint64_t publisher_submissions;
    uint64_t publisher_snapshots;
    uint64_t publisher_emitted;
    uint64_t publisher_emitted_native;
    uint64_t publisher_emitted_cpu;
    uint64_t publisher_stale;
    uint64_t publisher_evictions;
    uint64_t publisher_coalesced;
    uint64_t publisher_prepared_coalesces;
    uint64_t publisher_suppressed;
    uint64_t publisher_flushes;
    uint64_t publisher_empty_flushes;
    uint64_t publisher_pending;
    uint64_t publisher_demanded;
    uint64_t publisher_prepared;
    uint64_t video_sessions;
    uint64_t video_hardware;
    uint64_t video_software;
    uint64_t video_query_failures;
    uint64_t video_decoded;
    uint64_t video_dropped;
    uint64_t video_materializations;
    uint64_t mjpeg_handles;
    uint64_t mjpeg_decoded;
    uint64_t mjpeg_native;
    uint64_t mjpeg_data_fallbacks;
    uint64_t mjpeg_allocations;
    uint64_t mjpeg_late;
    uint64_t mjpeg_superseded;
    uint64_t mjpeg_peak_buffers;
    uint64_t mjpeg_peak_decodes;
    uint64_t advanced_cpu_fallbacks;
    uint64_t native_fallbacks;
    uint64_t native_disables;
    uint64_t first_disable_reason;
    SpiceZigPipelineTiming batch_start_gap;
    SpiceZigPipelineTiming framed_receive_batch_start_gap;
    SpiceZigPipelineTiming receive_to_ready;
    SpiceZigPipelineTiming ready_to_submit;
    SpiceZigPipelineTiming flush_start_gap;
    SpiceZigPipelineTiming flush_scheduling_delay;
    SpiceZigPipelineTiming snapshot_duration;
    SpiceZigPipelineTiming emit_duration;
} SpiceZigPipelineMetrics;
/* Read while Desktop is alive, after joining callers before destroy. */
int spice_zig_desktop_pipeline_metrics(SpiceZigDesktop *,SpiceZigPipelineMetrics *);
#ifdef __cplusplus
}
#endif
#endif
