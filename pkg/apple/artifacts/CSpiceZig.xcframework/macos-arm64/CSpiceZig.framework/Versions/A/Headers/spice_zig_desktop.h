#ifndef SPICE_ZIG_DESKTOP_H
#define SPICE_ZIG_DESKTOP_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Unreleased real desktop runtime, parallel to SwiftSpice. Protocol services
 * run in Zig; this does not claim host peripheral/filesystem/UI parity.
 * Create before blocking connect. cancel is thread safe and wakes all workers;
 * JOIN external connect/next/send callers before destroy. One next caller.
 * Returned events/frames own immutable data and survive desktop destruction.
 * All input memory is borrowed only until the synchronous call returns.
 * Destroy/release(NULL) is harmless. Other NULL arguments fail explicitly.
 * Status: 0 success, negative failure (-2 allocation, -30 timeout, -31 cancel,
 * -32 TLS, -33 connect, -34 EOF, -37 auth, -38 link, -39 auth method,
 * -50 Metal unavailable, -1 argument/protocol/state). An event error exposes
 * the stable error category name; it never includes credentials/payloads.
 */
typedef struct SpiceZigDesktop SpiceZigDesktop;
typedef struct SpiceZigDesktopEvent SpiceZigDesktopEvent;
typedef struct SpiceZigFrame SpiceZigFrame;
typedef struct SpiceZigDesktopSendToken SpiceZigDesktopSendToken;
typedef struct {const uint8_t *data;size_t size;} SpiceZigDesktopCertificate;
/* NULL metallib selects CPU Surface composition; a supplied path must load.
 * video: 0 MJPEG, 1 H264, 2 H265 (hardware decoder still validates actual use). */
int spice_zig_desktop_create(const char *compositor_metallib,uint8_t video,SpiceZigDesktop **out);
/* TLS modes match spice_zig.h. Certificates and security settings are copied.
 * Secret is at most 60 non-NUL bytes; no secrets are logged or persisted. */
int spice_zig_desktop_connect(SpiceZigDesktop *,const char *host,uint16_t port,
    uint8_t tls_kind,const char *server_name,const char *expected_subject,
    const SpiceZigDesktopCertificate *,size_t certificate_count,uint32_t timeout_ms,
    const uint8_t *secret,size_t secret_size);
/* Bootstrap snapshot for the active generation. Apply Main events for later
 * mouse/Agent updates. Channel lookup requires that exact generation so a
 * migration cannot mix two channel inventories. Main is not in this child list. */
typedef struct {
    uint64_t generation;
    uint32_t session_id,multimedia_time,supported_mouse_modes,current_mouse_mode,agent_connected,channel_count;
    uint64_t agent_epoch,lifecycle;
} SpiceZigDesktopInfo;
int spice_zig_desktop_info(SpiceZigDesktop *,SpiceZigDesktopInfo *);
int spice_zig_desktop_channel(SpiceZigDesktop *,uint64_t generation,size_t index,uint8_t *type,uint8_t *id);
void spice_zig_desktop_cancel(SpiceZigDesktop *);
/* After cancel, join internal supervision/receiver threads. Serialize join with
 * connect/reset/destroy; external callers still require their own join. */
void spice_zig_desktop_join(SpiceZigDesktop *);
/* Reuse a cancelled Runtime, preserving its address/native context for Sources.
 * First cancel and join external connect/next/send callers. Drain terminal
 * events through Source before reset to clear the old desktop. Reset joins
 * internal workers, drains abandoned queued payloads, clears diagnostics and
 * advances generation+guest lifecycle. Old retained events remain readable but
 * cannot enter a newer Source generation. Subscriptions retain their demand.
 * Ready/connecting runtimes reject reset. Idle runtime only updates video policy.
 * Video: 0 MJPEG, 1 H264, 2 H265. No endpoint/secret is retained from the old run. */
int spice_zig_desktop_reset(SpiceZigDesktop *,uint8_t video);
void spice_zig_desktop_destroy(SpiceZigDesktop *);
/* Blocking next: 1 owned event, 0 end, negative error. Allocation failure does
 * not consume the queued event. Metadata/data are borrowed until event destroy. */
int spice_zig_desktop_next(SpiceZigDesktop *,SpiceZigDesktopEvent **out);
void spice_zig_desktop_event_destroy(SpiceZigDesktopEvent *);
typedef struct {
    uint64_t generation;
    uint32_t kind,detail;
    uint8_t channel_type,channel_id;
    uint16_t reserved;
    uint32_t values[40];
    uint64_t wide[4];
} SpiceZigDesktopEventMetadata;
/* Event mappings (v=values,w=wide; unspecified fields are zero):
 * 1 connected, 2 disconnected, 3 failed (event_error).
 * 3 failed: detail0 generic; 1 video hardware unavailable; 2 unsupported video.
 *   For detail1/2, v0=codec(0 H264,1 H265), v1=hasStatus,v2=signed OSStatus bits.
 * 4 Main: detail1 mouse v=supported,current; 2 Agent connected;
 *   3 Agent disconnected v=code; 4 Agent message v=protocol,type,w0=opaque,data;
 *   5 raw migration data (normally consumed by supervisor).
 * 5 Display: detail1 create/2 destroy v0=Surface ID;
 *   3 mutation v0=Surface ID,w=lifecycle,revision;
 *   4 monitors v=maximum,count, use event_monitor; 5 ignored v0=wire kind.
 * 6 migration: detail1 preparing,2 ready,3 cancelled,4 committing,5 switching,
 *   6 completed,7 failed; w0=offer ID; v=seamless,port,TLSport,mode;
 *   mode0 semi,1 seamless,2 switch-host; v4=sourceVersion,v5=hasSubject;
 *   data=UTF8 destination host. Subject bytes use event_migration_subject.
 * 7 Inputs: detail1 init/2 modifiers v0=modifiers; 3 motion ACK.
 * 8 Cursor: detail1 initialized,2 updated,3 reset,4 cache invalidated;
 *   v=x,y,visible,trailLength,trailFrequency,hasImage,format,width,height,
 *     hotX,hotY,flags; x/y are signed int32 bit patterns; w0=image ID; data=pixels.
 * 9 Playback / 10 Record: detail1 RAW mode v0=time; Record START wide0=stream epoch;
 *   2 start v=channels,format(1/S16),frequency,time; 3 PCM v0=time,data=PCM;
 *   4 stop; 5 volume v=count,channel0,...channel31; 6 mute v0=boolean;
 *   7 latency v0=milliseconds.
 * 11 Smartcard: detail1 init v0=version,data=capabilities;
 *   2 completed v=requestType,reader,errorCode; 3 APDU v0=reader,data=APDU;
 *   4 flush v0=reader.
 * 12 USB: data=raw VMC bytes.
 * 13 WebDAV: detail1 init v0=opened,data=UTF8 port name; 2 port v0=event;
 *   3 request w0=signed int64 client bit pattern,data=bytes; 4 closed w0=client.
 * 14 publication: v=SurfaceID,fullDamage,hasTiming; w=lifecycle,revision,
 *   receivedNs,readyNs. Extract an owned frame; event_data does not read pixels.
 */
int spice_zig_desktop_event_metadata(const SpiceZigDesktopEvent *,SpiceZigDesktopEventMetadata *);
const uint8_t *spice_zig_desktop_event_data(const SpiceZigDesktopEvent *,size_t *);
const char *spice_zig_desktop_event_error(const SpiceZigDesktopEvent *);
/* Borrowed UTF8 subject; metadata v5 distinguishes absent from empty. */
const uint8_t *spice_zig_desktop_event_migration_subject(const SpiceZigDesktopEvent *,size_t *);
typedef struct {uint32_t id,surface,width,height,x,y,flags;} SpiceZigMonitor;
int spice_zig_desktop_event_monitor(const SpiceZigDesktopEvent *,size_t index,SpiceZigMonitor *);
int spice_zig_desktop_event_frame(const SpiceZigDesktopEvent *,SpiceZigFrame **out);
SpiceZigFrame *spice_zig_frame_retain(SpiceZigFrame *);
void spice_zig_frame_release(SpiceZigFrame *);
typedef struct {
    uint32_t surface_id,width,height,format;
    uint64_t lifecycle,revision;
    uint32_t native,damage_count;
    /* True only when this revision was committed by H.264/H.265 rendering. */
    uint32_t advanced_video,reserved;
} SpiceZigFrameInfo;
typedef struct {int32_t x,y;uint32_t width,height;} SpiceZigDamageRect;
int spice_zig_frame_info(const SpiceZigFrame *,SpiceZigFrameInfo *);
int spice_zig_frame_damage(const SpiceZigFrame *,size_t index,SpiceZigDamageRect *);
/* Tight top-down immutable BGRA, width*height*4. Native readback happens only
 * on this call, once per underlying publication. Safe concurrent read access;
 * borrowed pointer remains valid until the last frame release. */
int spice_zig_frame_pixels(SpiceZigFrame *,const uint8_t **out,size_t *size);
/* Writes exactly width*height*4 tight BGRA bytes into caller-owned memory.
 * Size mismatch is rejected before writing. Destination must not overlap any
 * frame storage. Intended for mutable/value-semantic host byte arrays; unlike
 * frame_pixels, it does not create a redundant native cache. A successful direct
 * IOSurface read counts as one materialization; caller caches its own result.
 * Frame backing remains immutable. */
int spice_zig_frame_copy_pixels(SpiceZigFrame *,uint8_t *destination,size_t size);
/* Borrowed native objects; NULL for CPU frames. Retain the frame through every
 * GPU command that uses these objects; retaining the texture alone is not a
 * frame-pool lease. */
void *spice_zig_frame_texture(const SpiceZigFrame *);
void *spice_zig_frame_iosurface(const SpiceZigFrame *);
/* Explicit demand defaults off. Acknowledge after selecting/consuming a frame
 * to permit another prepared publication. Same-ID recreation is lifecycle safe. */
int spice_zig_desktop_set_demand(SpiceZigDesktop *,uint8_t channel,uint32_t surface,uint8_t demanded);
int spice_zig_desktop_acknowledge_frame(SpiceZigDesktop *,uint8_t channel,uint32_t surface,uint64_t lifecycle,uint64_t revision);
/* Raw protocol send is available for extension messages. Prefer typed services
 * below for stateful Inputs/Record/Smartcard/VMC/WebDAV operations. */
int spice_zig_desktop_send(SpiceZigDesktop *,uint8_t channel_type,uint8_t channel_id,uint16_t message,const uint8_t *,size_t);
/* input kind0 key down,1 up (x=PC XT code),2 modifiers(x),3 relative(x,y),
 * 4 absolute(x/y uint32 bit patterns,display),5 press/6 release(x=button1..7). */
int spice_zig_desktop_input(SpiceZigDesktop *,uint8_t channel,uint8_t kind,int32_t x,int32_t y,uint8_t display);
int spice_zig_desktop_record(SpiceZigDesktop *,uint8_t channel,uint8_t begin,uint32_t time,const uint8_t *,size_t);
int spice_zig_desktop_playback_delay(SpiceZigDesktop *,uint8_t channel,uint32_t delay_ms);
int spice_zig_desktop_smartcard(SpiceZigDesktop *,uint8_t channel,uint32_t kind,uint32_t reader,const uint8_t *,size_t);
int spice_zig_desktop_usb(SpiceZigDesktop *,uint8_t channel,const uint8_t *,size_t);
int spice_zig_desktop_webdav(SpiceZigDesktop *,uint8_t channel,int64_t client,const uint8_t *,size_t);
/* One token per send. Cancel wakes its exact pinned sender across migration;
 * JOIN the send caller before token destruction. agent: 1 sent,0 insufficient
 * tokens/no bytes sent,negative error. Payload limit 16 MiB. */
SpiceZigDesktopSendToken *spice_zig_desktop_send_token_create(void);
void spice_zig_desktop_send_token_cancel(SpiceZigDesktopSendToken *);
void spice_zig_desktop_send_token_destroy(SpiceZigDesktopSendToken *);
int spice_zig_desktop_agent(SpiceZigDesktop *,uint32_t protocol,uint32_t kind,uint64_t opaque,const uint8_t *,size_t,SpiceZigDesktopSendToken *);
/* Fenced send for work originating from an Agent event. Main Agent events
 * expose the Agent epoch in metadata.wide[1] and stable session identity in
 * metadata.wide[2]. Bootstrap contains initial agent_epoch and lifecycle.
 * Session identity survives migration but changes on switch-host. Returns -45 for
 * stale work without reserving tokens or writing bytes, 0 for backpressure,
 * 1 for one complete message. Epoch checks occur under their owning locks. */
int spice_zig_desktop_agent_at(SpiceZigDesktop *,uint64_t session_epoch,uint64_t agent_epoch,uint32_t protocol,uint32_t kind,uint64_t opaque,const uint8_t *,size_t,SpiceZigDesktopSendToken *);
/* Native submitter is independent of Desktop lifetime after create. Use the
 * existing presentation shader metallib, distinct from the compositor shader.
 * Host acquires a fresh drawable during its actual draw cycle. Texture must be
 * BGRA, from the source frame's Metal device, and support render-target usage
 * (nearest) or shader-write usage (Lanczos). NULL drawable allows offscreen use.
 * A successful submit retains frame and native destination until GPU completion.
 * Completion is not evidence of onscreen presentation; its current flag fences
 * reset/hide/destroy epochs. Callback runs on a Metal thread, must return, and
 * must not call destroy/wait_idle on its own presenter. Join external submit
 * calls before destroy; destroy waits for all native work and callbacks.
 */
typedef struct SpiceZigDesktopPresenter SpiceZigDesktopPresenter;
typedef struct {
    uint32_t surface_id,reserved;
    uint64_t lifecycle,revision,epoch;
    uint32_t succeeded,current;
} SpiceZigPresentationCompletion;
typedef void (*SpiceZigPresentationCallback)(void *,const SpiceZigPresentationCompletion *);
int spice_zig_desktop_presenter_create(SpiceZigDesktop *,const char *presentation_metallib,
    SpiceZigPresentationCallback,void *user,SpiceZigDesktopPresenter **out);
void spice_zig_desktop_presenter_destroy(SpiceZigDesktopPresenter *);
int spice_zig_desktop_presenter_reset(SpiceZigDesktopPresenter *,uint8_t visible);
/* 0 submitted,1 GPU busy (no submission),2 hidden,3 stale,negative error.
 * No completion is delivered for a non-submitted result. */
int spice_zig_desktop_presenter_submit(SpiceZigDesktopPresenter *,const SpiceZigFrame *,
    void *texture,uint32_t width,uint32_t height,void *optional_CAMetalDrawable);
/* Optional native observations. Submit on MAIN THREAD. Callbacks are queued on
 * the main queue; they cannot overtake submit's returned commit_ns on that thread.
 * stage 1=GPU completion(status0 success,-1 failure), 2=drawable outcome
 * (status0 actual presentation,-1 dropped; media_time=0 on drop).
 * continuous_ns, media_now and media_time permit callback-local clock conversion.
 * Observer context is independently retained until native/queued blocks release
 * it; retain/release may execute on any thread. Context MUST NOT borrow the
 * presenter or other freed user storage. It can outlive presenter destruction.
 * wait_idle joins GPU completion callbacks, NOT pending main-queue observations.
 * Without a drawable there is no stage 2. No timestamp is inferred from stage 1.
 * commit_ns is zero for every non-submitted result. */
typedef struct {
    uint32_t stage;int32_t status;uint64_t continuous_ns;
    double media_time,media_now;
} SpiceZigPresentationObservation;
typedef struct {
    void *context;
    void (*retain)(void *);
    void (*release)(void *);
    void (*event)(void *,const SpiceZigPresentationObservation *);
} SpiceZigPresentationObserver;
int spice_zig_desktop_presenter_submit_observed(SpiceZigDesktopPresenter *,const SpiceZigFrame *,
    void *texture,uint32_t width,uint32_t height,void *optional_CAMetalDrawable,
    const SpiceZigPresentationObserver *,uint64_t *commit_ns);
void spice_zig_desktop_presenter_wait_idle(SpiceZigDesktopPresenter *);
#ifdef __cplusplus
}
#endif
#endif
