#ifndef SPICE_ZIG_AGENT_H
#define SPICE_ZIG_AGENT_H
#include "spice_zig_desktop.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Optional desktop Agent services. One serialized owner calls manager APIs and
 * delivers every Desktop event in receive order. Observe borrows the event.
 * Manager borrows Desktop: join manager callers and destroy manager BEFORE
 * Desktop. Token cancellation may run concurrently. Callbacks must not reenter.
 * No system pasteboard reads are implicit. The owner supplies local snapshots
 * only when synchronization is permitted and drives pump on its worker/poll.
 */
typedef struct SpiceZigAgentManager SpiceZigAgentManager;
typedef struct SpiceZigAgentEvent SpiceZigAgentEvent;
typedef struct {
    size_t maximum_text_bytes,maximum_pending_bytes,maximum_concurrent_files;
    uint64_t maximum_file_bytes;
    size_t file_chunk_bytes;
    uint8_t clipboard_enabled,reserved[7];
} SpiceZigAgentOptions;
void spice_zig_agent_options(SpiceZigAgentOptions *);
/* 0 successful write with returned host change count, nonzero failure. Text is
 * borrowed for this call. Honor token cancellation; do not retain token/text.
 * Required when clipboard_enabled is true. This callback is never called while
 * synchronization is disabled; disabling also revokes pending failed writes. */
typedef int (*SpiceZigAgentWriteText)(void *,const uint8_t *,size_t,int64_t *change_count,SpiceZigDesktopSendToken *);
int spice_zig_agent_token_cancelled(SpiceZigDesktopSendToken *);
int spice_zig_agent_manager_create(SpiceZigDesktop *,const SpiceZigAgentOptions *,SpiceZigAgentWriteText,void *,SpiceZigAgentManager **out);
void spice_zig_agent_manager_destroy(SpiceZigAgentManager *);
int spice_zig_agent_manager_observe(SpiceZigAgentManager *,const SpiceZigDesktopEvent *);
/* pump: 0 idle,1 blocked/no-byte token admission,2 more work; negative error.
 * Bound each turn (e.g.64); reschedule on 2, retry 1 after tokens/events/poll.
 * Transport errors retire the Agent epoch and never replay uncertain effects.
 * Host write failures retain that action until retry or access revocation. */
int spice_zig_agent_manager_pump(SpiceZigAgentManager *,SpiceZigDesktopSendToken *,size_t maximum_operations);
int spice_zig_agent_manager_enable_clipboard(SpiceZigAgentManager *,uint8_t enabled);
/* present0 absent text; present1 includes empty string. UTF-8 <=16MiB. */
int spice_zig_agent_manager_local_text(SpiceZigAgentManager *,int64_t change_count,uint8_t present,const uint8_t *,size_t);
typedef struct {int64_t id,x,y,width,height;} SpiceZigRequestedMonitor;
int spice_zig_agent_manager_request_display(SpiceZigAgentManager *,const SpiceZigRequestedMonitor *,size_t);
typedef struct {uint32_t id,reserved;uint64_t incarnation;} SpiceZigFileKey;
/* Explicit source path and guest basename, each <=4096 bytes. Opens read-only;
 * only regular files accepted. Descriptor remains pinned through pending reads.
 * FileKey includes incarnation, so old cancellation cannot hit a reused ID. */
int spice_zig_agent_manager_send_file(SpiceZigAgentManager *,const uint8_t *path,size_t path_size,const uint8_t *name,size_t name_size,SpiceZigFileKey *out);
int spice_zig_agent_manager_cancel_file(SpiceZigAgentManager *,SpiceZigFileKey);
/* Queue holds 64 owned events. Drain after each observe/operation/pump turn.
 * Overflow is terminal -46; already queued events remain readable. next allocates
 * BEFORE consuming: 1 event,0 empty,negative failure. Events outlive manager. */
int spice_zig_agent_manager_next(SpiceZigAgentManager *,SpiceZigAgentEvent **out);
void spice_zig_agent_event_destroy(SpiceZigAgentEvent *);
typedef struct {uint32_t kind,detail,values[8];uint64_t wide[4];} SpiceZigAgentEventInfo;
/* kind1 clipboard: detail1 ready,2 unavailable,3 guest text(data),4 local offered
 * (wide0 bytes),5 oversized(wide0 bytes,wide1 maximum).
 * kind2 support: values0 bits0 connected,1 explicit caps,2 monitors,3 sparse,
 * 4 positions,5 file capability state,6 files allowed,7 detailed file errors.
 * kind3 display: detail1 queued,2 sent,3 ack,4 rejected,5 unsupported,6 failed;
 * wide0 request ID,values0 monitor count; event_monitor returns original layout.
 * kind4 files: detail1 queued,2 awaiting approval,3 progress,4 complete,5 cancel,
 * 6 failed. values0 ID,wide0 incarnation,wide1 sent,wide2 total. Queued data=name.
 * Failed: values1 has-ID,values2 detail0 none/1 GLib/2 disk-free; wide2 detail.
 * event_error returns a fixed content-free category for display/file failures. */
int spice_zig_agent_event_info(const SpiceZigAgentEvent *,SpiceZigAgentEventInfo *);
const uint8_t *spice_zig_agent_event_data(const SpiceZigAgentEvent *,size_t *);
const char *spice_zig_agent_event_error(const SpiceZigAgentEvent *);
int spice_zig_agent_event_monitor(const SpiceZigAgentEvent *,size_t,SpiceZigRequestedMonitor *);
/* Optional native executor: retains a named/general pasteboard context, polls
 * every poll_ms (>=10; normally 250; 0 disables automatic host reads), retries token backpressure, joins on
 * destroy. General pasteboard access is explicit (general=1, empty name), and
 * no access occurs while options.clipboard_enabled=0. Use private named boards
 * in tests. Keep feeding ordered Desktop events; do not use a second manager for
 * the same Agent stream. Only AppKit access is dispatched to the main queue.
 * APIs are thread-safe; join callers before destroy. Desktop must outlive runner.
 * Enable/disable takes effect on queued host access immediately; already running
 * AppKit effects finish before stop/destroy returns. No implicit network retries
 * follow an uncertain send. Main must service its run loop during normal use.
 * Commands and output queues each hold 64 entries, with 32MiB payload bounds.
 * -47 means input queue full (observation not accepted, caller may retry in order).
 * A failed enable/disable due to a full queue terminates the runner and revokes
 * host access. Output overflow is terminal -46. Drain both events and status.
 */
typedef struct SpiceZigAgentRunner SpiceZigAgentRunner;
typedef struct SpiceZigAgentRunnerEvent SpiceZigAgentRunnerEvent;
int spice_zig_agent_runner_create(SpiceZigDesktop *,const SpiceZigAgentOptions *,const uint8_t *name,size_t name_size,uint8_t general,uint32_t poll_ms,SpiceZigAgentRunner **out);
void spice_zig_agent_runner_stop(SpiceZigAgentRunner *);
void spice_zig_agent_runner_destroy(SpiceZigAgentRunner *);
/* status 0 running,1 finished,negative terminal failure. next 1 event,0 empty. */
int spice_zig_agent_runner_status(SpiceZigAgentRunner *);
int spice_zig_agent_runner_observe(SpiceZigAgentRunner *,const SpiceZigDesktopEvent *);
int spice_zig_agent_runner_enable_clipboard(SpiceZigAgentRunner *,uint8_t enabled);
int spice_zig_agent_runner_request_display(SpiceZigAgentRunner *,uint64_t request,const SpiceZigRequestedMonitor *,size_t);
/* request is a caller correlation ID. File admission/key is asynchronous;
 * success/failure is delivered as a runner event. Opens only regular files. */
int spice_zig_agent_runner_send_file(SpiceZigAgentRunner *,uint64_t request,const uint8_t *path,size_t,const uint8_t *name,size_t);
int spice_zig_agent_runner_cancel_file(SpiceZigAgentRunner *,uint64_t request,SpiceZigFileKey);
int spice_zig_agent_runner_next(SpiceZigAgentRunner *,SpiceZigAgentRunnerEvent **out);
void spice_zig_agent_runner_event_destroy(SpiceZigAgentRunnerEvent *);
typedef struct {uint32_t kind,reserved;uint64_t request;SpiceZigFileKey key;} SpiceZigAgentRunnerEventInfo;
/* kind1 Agent event,2 failure(request0 means protocol/poll),3 accepted file key,
 * 4 completed request. Request completion follows one bounded pump turn.
 * Returned Agent pointer is borrowed from the runner event; never destroy it
 * separately. Owned runner events remain valid after runner/Desktop destruction. */
int spice_zig_agent_runner_event_info(const SpiceZigAgentRunnerEvent *,SpiceZigAgentRunnerEventInfo *);
const SpiceZigAgentEvent *spice_zig_agent_runner_event_agent(const SpiceZigAgentRunnerEvent *);
const char *spice_zig_agent_runner_event_error(const SpiceZigAgentRunnerEvent *);
/* First file ID preserves one public manager's identity across stop/start.
 * Zero is invalid. Other parameters/ownership match the original create API. */
int spice_zig_agent_runner_create_seeded(SpiceZigDesktop *,const SpiceZigAgentOptions *,const uint8_t *,size_t,uint8_t,uint32_t,uint32_t first_file_id,SpiceZigAgentRunner **);
/* Owner-only joined stop; no concurrent join/destroy caller. Detach first. */
void spice_zig_agent_runner_join(SpiceZigAgentRunner *);
uint32_t spice_zig_agent_runner_next_file_id(SpiceZigAgentRunner *);
/* Nonzero request IDs correlate completion/failure. Publish is policy-fenced;
 * neither synchronize nor publish accesses the host while disabled. Barrier
 * joins prior admitted work, without waiting for guest replies/token credit. */
int spice_zig_agent_runner_synchronize(SpiceZigAgentRunner *,uint64_t request);
/* Blocking local publication. Call off main, retaining runner and text until
 * return. Oversized text stays local; wire and owned queue limits are unchanged. */
int spice_zig_agent_runner_publish_borrowed(SpiceZigAgentRunner *,const uint8_t *,size_t);
int spice_zig_agent_runner_publish(SpiceZigAgentRunner *,uint64_t request,const uint8_t *,size_t);
int spice_zig_agent_runner_barrier(SpiceZigAgentRunner *,uint64_t request);
int spice_zig_agent_runner_event_limits(const SpiceZigAgentRunnerEvent *,uint64_t *actual,uint64_t *maximum);
typedef struct {
    uint64_t capability_attempts;
    uint64_t capability_sent;
    uint64_t capability_failures;
    uint64_t inbound;
    uint64_t current_protocol;
    uint64_t unexpected_protocol;
    uint64_t capabilities;
    uint64_t clipboard;
    uint64_t data;
    uint64_t grab;
    uint64_t request;
    uint64_t release;
    uint64_t monitor_replies;
    uint64_t files;
    uint64_t other;
    uint64_t decode_failures;
    uint64_t clipboard_failures;
    uint32_t has_peer;
    uint32_t peer_legacy;
    uint32_t peer_demand;
    uint32_t last_failure;
    uint32_t has_inbound;
    uint32_t last_protocol;
    uint32_t last_kind;
    uint32_t reserved;
} SpiceZigAgentMetrics;
/* Best effort worker-turn snapshot, content-free and cumulative per runner. */
int spice_zig_agent_runner_metrics(SpiceZigAgentRunner *,SpiceZigAgentMetrics *);
/* Optional single-consumer late attachment. Feed ordered Desktop events.
 * A newest64/32MiB replay cache is independent of public stream consumption.
 * Fresh guest/terminal events retire the cache. Detach joins observations;
 * borrowed runner must outlive detach. Join callers/detach before destroy. */
typedef struct SpiceZigAgentRoute SpiceZigAgentRoute;
int spice_zig_agent_route_create(SpiceZigAgentRoute **);
void spice_zig_agent_route_destroy(SpiceZigAgentRoute *);
int spice_zig_agent_route_observe(SpiceZigAgentRoute *,const SpiceZigDesktopEvent *);
int spice_zig_agent_route_attach(SpiceZigAgentRoute *,SpiceZigAgentRunner *);
void spice_zig_agent_route_detach(SpiceZigAgentRoute *,SpiceZigAgentRunner *);
#ifdef __cplusplus
}
#endif
#endif
