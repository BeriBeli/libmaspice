#ifndef SPICE_ZIG_WEBDAV_H
#define SPICE_ZIG_WEBDAV_H
#include "spice_zig_desktop.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Optional native HTTP/filesystem backend. The application explicitly supplies
 * an authorized absolute root (UTF-8, byte-counted, no NUL). Defaults are read-only.
 * Feed Desktop events in receive order, before releasing them. Observe borrows
 * the event; accepted request storage becomes service-owned. One backend owns
 * the selected channel's requests; do not also send independent responses.
 * Methods are thread-safe except destroy, which requires exclusive ownership.
 * Destroy BEFORE Desktop; it cancels sends and joins all filesystem/worker work.
 * Closing a client retires queued requests; already-entered filesystem effects
 * can complete, their responses are discarded, and effects are never retried.
 * Same-ID reuse waits for those old owners. A failed send prevents later writes.
 * Cancellation of an uncertain in-flight write closes the pinned WebDAV channel
 * to preserve framing. Idle cancellation does not close a transport.
 * A bounded worker per job slot prevents blocked sends from occupying filesystem
 * permits. Jobs must be 1..64; parallelism must be 1..maximum_jobs. Stop is terminal.
 * Observe/admission errors terminate this backend. Poll status to detect worker
 * failures and end the associated consumer session; no failure is silently retried.
 * No network listener is opened. Requests arrive over the SPICE WebDAV channel. */
typedef struct SpiceZigWebDAV SpiceZigWebDAV;
typedef struct {
    uint8_t channel_id,read_write,reserved[6];
    size_t filesystem_parallelism,maximum_clients,maximum_jobs;
    size_t maximum_retained_bytes,maximum_header_bytes,maximum_body_bytes;
} SpiceZigWebDAVOptions;
void spice_zig_webdav_options(SpiceZigWebDAVOptions *);
int spice_zig_webdav_create(SpiceZigDesktop *,const uint8_t *root,size_t root_size,
                           const SpiceZigWebDAVOptions *,SpiceZigWebDAV **out);
int spice_zig_webdav_observe(SpiceZigWebDAV *,const SpiceZigDesktopEvent *);
void spice_zig_webdav_stop(SpiceZigWebDAV *);
void spice_zig_webdav_destroy(SpiceZigWebDAV *);
/* 0 running; 1 stopped and workers finished; negative terminal error.
 * Optional category is static, content-free and valid after destruction. */
int spice_zig_webdav_status(SpiceZigWebDAV *,const char **error_category);
typedef struct {
    uint64_t clients,buffered_bytes,pending_jobs,pending_bytes,reserved_bytes;
    uint64_t peak_jobs,peak_bytes,completed,cancelled,rejected,discarded;
} SpiceZigWebDAVDiagnostics;
int spice_zig_webdav_diagnostics(SpiceZigWebDAV *,SpiceZigWebDAVDiagnostics *);
/* One reference-counted server may be attached to several channels/sessions.
 * Each attachment retains its filesystem, client state and shared bounds.
 * Standalone receive serializes callers and returns separately owned responses.
 * It rejects client IDs owned by the asynchronous pipeline (and vice versa).
 * Close-all retires outstanding work for every attachment; it does not retry
 * effects already in flight. Returned response storage survives server release. */
typedef struct SpiceZigWebDAVServer SpiceZigWebDAVServer;
typedef struct SpiceZigWebDAVResponses SpiceZigWebDAVResponses;
typedef struct SpiceZigWebDAVRoute SpiceZigWebDAVRoute;
int spice_zig_webdav_server_create(const uint8_t *,size_t,const SpiceZigWebDAVOptions *,SpiceZigWebDAVServer **);
void spice_zig_webdav_server_destroy(SpiceZigWebDAVServer *);
int spice_zig_webdav_server_receive(SpiceZigWebDAVServer *,int64_t,const uint8_t *,size_t,SpiceZigWebDAVResponses **);
void spice_zig_webdav_server_close(SpiceZigWebDAVServer *,int64_t,uint8_t all);
size_t spice_zig_webdav_responses_count(const SpiceZigWebDAVResponses *);
const uint8_t *spice_zig_webdav_responses_bytes(const SpiceZigWebDAVResponses *,size_t,size_t *);
void spice_zig_webdav_responses_destroy(SpiceZigWebDAVResponses *);
int spice_zig_webdav_create_shared(SpiceZigDesktop *,uint8_t,SpiceZigWebDAVServer *,SpiceZigWebDAV **);
int spice_zig_webdav_route_create(SpiceZigWebDAVRoute **);
void spice_zig_webdav_route_destroy(SpiceZigWebDAVRoute *);
int spice_zig_webdav_route_attach(SpiceZigWebDAVRoute *,SpiceZigDesktop *,SpiceZigWebDAV *);
void spice_zig_webdav_route_detach(SpiceZigWebDAVRoute *,SpiceZigWebDAV *);
/* Returns 1 when attached service consumed the channel event, 0 otherwise. */
int spice_zig_webdav_route_observe(SpiceZigWebDAVRoute *,const SpiceZigDesktopEvent *);
#ifdef __cplusplus
}
#endif
#endif
