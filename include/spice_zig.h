#ifndef SPICE_ZIG_H
#define SPICE_ZIG_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Unreleased foundational API, not a complete SPICE client API.
 * One serialized executor owns each wire handle. A batch owns immutable bytes
 * and may be moved to another executor; destroy only after every reader ends.
 * Pointers returned by batch_message remain valid until batch_destroy, even
 * after wire reset/destroy. No callbacks and no borrowed append storage.
 * Destroy(NULL)/reset(NULL) are harmless; double-destroy is invalid.
 * Errors: -1 invalid argument, -2 allocation, -3 truncated, -4 offset,
 * -5 overflow, -6 byte/message/submessage limit, -7 segments, -8 size.
 */
typedef struct SpiceZigWire SpiceZigWire;
typedef struct SpiceZigBatch SpiceZigBatch;
typedef struct SpiceZigImage SpiceZigImage;
typedef struct SpiceZigTransport SpiceZigTransport;
typedef struct SpiceZigLink SpiceZigLink;
typedef struct { const uint8_t *data; size_t size; } SpiceZigCertificate;
/* Worker-facing blocking I/O. Create starts a fresh native connection; connect
 * waits for readiness. One reader and one writer may operate concurrently.
 * cancel is thread-safe/idempotent and unblocks connect/read/write. Cancel and
 * JOIN callers before destroy. Never use any handle after its destroy.
 * TLS kinds: 0 TCP, 1 system trust, 2 custom CA with hostname/SAN/EKU,
 * 3 virt-viewer CA + complete ordered subject, 4 explicitly insecure testing.
 * Certificates may be DER, PEM bundles, or escaped PEM; copied at creation.
 * Verification owns its immutable policy independently until callbacks finish.
 * Errors: -30 timeout, -31 cancelled, -32 TLS, -33 connect/I/O, -34 closed,
 * -35 operation already active, -36 invalid certificate; -1 invalid argument.
 * No retry of an uncertain write. Max single I/O 64MiB. Timeout covers connect.
 */
int spice_zig_transport_create(const char *host, uint16_t port, uint8_t tls_kind,
    const char *server_name, const char *expected_subject,
    const SpiceZigCertificate *certificates, size_t count, uint32_t timeout_ms,
    SpiceZigTransport **out);
int spice_zig_transport_connect(SpiceZigTransport *);
void spice_zig_transport_cancel(SpiceZigTransport *);
void spice_zig_transport_destroy(SpiceZigTransport *);
int spice_zig_transport_read(SpiceZigTransport *, uint8_t *, size_t capacity, size_t minimum, size_t *received);
int spice_zig_transport_read_exact(SpiceZigTransport *, uint8_t *, size_t);
int spice_zig_transport_write(SpiceZigTransport *, const uint8_t *, size_t);
/* Owns *out only after the real authenticated Link exchange. Every failure
 * cancels transport; credentials are borrowed synchronously and never stored.
 * Additional errors: -37 ticket rejected, -38 link rejected, -39 auth method.
 */
int spice_zig_link_handshake(SpiceZigTransport *, uint32_t connection_id,
    uint8_t channel_type, uint8_t channel_id, const uint32_t *common, size_t common_count,
    const uint32_t *channel, size_t channel_count, const uint8_t *password, size_t password_size,
    SpiceZigLink **out);
void spice_zig_link_destroy(SpiceZigLink *);
int spice_zig_link_mode(const SpiceZigLink *);
const uint32_t *spice_zig_link_capabilities(const SpiceZigLink *, uint8_t channel, size_t *count);
/* Session ownership layer. Successful channel handles are BORROWED until
 * session destruction; never destroy them independently. Callers choose explicit
 * capabilities; typed Main/Display/etc. services are separate migration work.
 * One receive/complete/configure-ACK worker per channel; send may be concurrent.
 * Cancel the session and JOIN all connect/send/receive/wait callers before destroy.
 * Every returned event owns immutable bytes until event_destroy, independently
 * of its channel/session. receive: 0 message (must complete AFTER handler),
 * 1 migration (already completed), negative error. No automatic message handling.
 * Additional errors: -40 duplicate key, -41 channel limit, -42 terminated serial
 * requirement, -43 invalid migration. Session cancellation requires a new session.
 */
typedef struct SpiceZigSession SpiceZigSession;
typedef struct SpiceZigConnection SpiceZigConnection;
typedef struct SpiceZigEvent SpiceZigEvent;
typedef struct SpiceZigWait SpiceZigWait;
typedef struct { uint8_t type, id; uint64_t serial; } SpiceZigSerialRequirement;
SpiceZigSession *spice_zig_session_create(size_t maximum_channels);
void spice_zig_session_cancel(SpiceZigSession *);
void spice_zig_session_destroy(SpiceZigSession *);
int spice_zig_session_connect(SpiceZigSession *, const char *host, uint16_t port,
    uint8_t tls_kind, const char *server_name, const char *expected_subject,
    const SpiceZigCertificate *, size_t certificate_count, uint32_t timeout_ms,
    uint32_t connection_id, uint8_t channel_type, uint8_t channel_id,
    const uint32_t *common, size_t common_count, const uint32_t *channel, size_t channel_count,
    const uint8_t *password, size_t password_size, SpiceZigConnection **out);
int spice_zig_channel_receive(SpiceZigConnection *, SpiceZigEvent **out);
int spice_zig_channel_complete(SpiceZigConnection *);
void spice_zig_channel_set_ack(SpiceZigConnection *, uint32_t generation, uint32_t window);
int spice_zig_channel_send(SpiceZigConnection *, uint16_t type, const uint8_t *, size_t);
void spice_zig_event_destroy(SpiceZigEvent *);
const uint8_t *spice_zig_event_data(const SpiceZigEvent *, size_t *);
int spice_zig_event_kind(const SpiceZigEvent *);
uint64_t spice_zig_event_serial(const SpiceZigEvent *);
/* Wait tokens belong to one session, are single-use, and must outlive wait/cancel.
 * Join those calls before token destruction. Cancel affects only this token. */
SpiceZigWait *spice_zig_wait_create(void);
void spice_zig_wait_destroy(SpiceZigWait *);
void spice_zig_wait_cancel(SpiceZigSession *, SpiceZigWait *);
int spice_zig_session_wait(SpiceZigSession *, const SpiceZigSerialRequirement *, size_t, SpiceZigWait *);
/* Typed Main service borrows its session-owned connection. Exactly one Main
 * service/receive owner may use a connection. Destroy Main BEFORE its session,
 * after cancel and joining Main/Agent callers. Bootstrap and events are owned.
 * Main drives the session's native continuous multimedia clock.
 * bootstrap/next return -44 for channel migration: take_migration transfers
 * the already completed migration data without cancelling the source.
 */
typedef struct SpiceZigMain SpiceZigMain;
typedef struct SpiceZigMainBootstrap SpiceZigMainBootstrap;
typedef struct SpiceZigMainEvent SpiceZigMainEvent;
typedef struct SpiceZigAgentSendToken SpiceZigAgentSendToken;
typedef struct {
    uint32_t session_id, multimedia_time, supported_mouse_modes, current_mouse_mode, agent_connected;
} SpiceZigMainInfo;
/* kind: 1 mouse (value supported, auxiliary current), 2 Agent connected,
 * 3 Agent disconnected (value error), 4 Agent message (protocol/value/opaque),
 * 5 validated Main migration (wire_kind + original owned body),
 * 6 channel migration (optional owned bytes). */
typedef struct {
    uint16_t kind, wire_kind;
    uint32_t protocol, value, auxiliary;
    uint64_t opaque;
} SpiceZigMainEventMetadata;
SpiceZigMain *spice_zig_main_create(SpiceZigConnection *);
void spice_zig_main_cancel(SpiceZigMain *);
void spice_zig_main_destroy(SpiceZigMain *);
int spice_zig_main_bootstrap(SpiceZigMain *, SpiceZigMainBootstrap **out);
void spice_zig_main_bootstrap_destroy(SpiceZigMainBootstrap *);
int spice_zig_main_bootstrap_info(const SpiceZigMainBootstrap *, SpiceZigMainInfo *);
/* Borrowed type/id byte pairs, count is the number of pairs. */
const uint8_t *spice_zig_main_bootstrap_channels(const SpiceZigMainBootstrap *, size_t *count);
/* 1 owned event, 0 handled control with no event, negative error. */
int spice_zig_main_next(SpiceZigMain *, SpiceZigMainEvent **out);
int spice_zig_main_take_migration(SpiceZigMain *, SpiceZigMainEvent **out);
void spice_zig_main_event_destroy(SpiceZigMainEvent *);
const uint8_t *spice_zig_main_event_data(const SpiceZigMainEvent *, size_t *size);
int spice_zig_main_event_metadata(const SpiceZigMainEvent *, SpiceZigMainEventMetadata *);
/* Tokens are single-use, bound to one Main service, and must outlive send/cancel.
 * 1 sent, 0 insufficient tokens (no bytes emitted), negative error. */
SpiceZigAgentSendToken *spice_zig_agent_send_token_create(void);
void spice_zig_agent_send_token_destroy(SpiceZigAgentSendToken *);
void spice_zig_agent_send_cancel(SpiceZigMain *, SpiceZigAgentSendToken *);
int spice_zig_agent_send(SpiceZigMain *, uint32_t protocol, uint32_t type, uint64_t opaque,
    const uint8_t *, size_t, SpiceZigAgentSendToken *);
/* mode 0 full, 1 mini; defaults: 64MiB message, 128MiB buffer, 4096 segments. */
SpiceZigWire *spice_zig_wire_create(uint8_t mode, size_t message_limit, size_t buffered_limit, size_t segment_limit);
void spice_zig_wire_destroy(SpiceZigWire *);
void spice_zig_wire_reset(SpiceZigWire *);
int spice_zig_wire_append(SpiceZigWire *, const uint8_t *, size_t);
/* 1 owns *out, 0 incomplete, negative error. *out is NULL on non-success.
 * maximum_submessages <= 4096. A batch always represents ONE physical ACK,
 * including an empty list; acknowledge after all its logical messages finish. */
int spice_zig_wire_next(SpiceZigWire *, size_t maximum_submessages, SpiceZigBatch **out);
size_t spice_zig_wire_buffered(const SpiceZigWire *);
void spice_zig_batch_destroy(SpiceZigBatch *);
size_t spice_zig_batch_count(const SpiceZigBatch *);
/* 1 full header (writes serial), 0 mini header (does not write), -1 invalid. */
int spice_zig_batch_serial(const SpiceZigBatch *, uint64_t *);
int spice_zig_batch_message(const SpiceZigBatch *, size_t index, uint16_t *type, const uint8_t **body, size_t *size);
/* Apple Security RSA-1024 OAEP-SHA1. Output is exactly 128 bytes, unchanged on
 * error. Password is borrowed, <=60 bytes without NUL; Zig appends the protocol
 * NUL in private storage and securely erases that copy. Caller owns its secret.
 * Errors -10 length, -11 NUL, -12 DER, -13 unsupported key, -14 encryption. */
int spice_zig_ticket_encrypt(const uint8_t *password, size_t password_size,
                             const uint8_t *public_key_der, size_t key_size,
                             uint8_t output[128]);
/* Truecolor/alpha LZ uses NULL palette; palette LZ uses ARGB entries. Input is
 * borrowed synchronously. Success owns *out; errors leave it NULL. Defaults:
 * 16384 axes, 64MiB encoded, 256MiB decoded, 256 palette entries. Image storage
 * is packed BGRA, in the encoded orientation, immutable until destroy.
 * Additional errors: -20 malformed, -21 dimensions, -22 mismatch, -23 format. */
int spice_zig_lz_decode(const uint8_t *data, size_t size, size_t width, size_t height,
                        const uint32_t *palette, size_t palette_count, SpiceZigImage **out);
void spice_zig_image_destroy(SpiceZigImage *);
const uint8_t *spice_zig_image_data(const SpiceZigImage *, size_t *size);
/* bit 0 top-down; bit 1 straight alpha (otherwise opaque XRGB). */
int spice_zig_image_flags(const SpiceZigImage *);
#ifdef __cplusplus
}
#endif
#endif
