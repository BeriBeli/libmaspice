// Independent upstream C decoder oracle, linked only by the validation harness.
#include <quic/shim.h>

typedef struct {
    SpiceSwiftQuicBridge bridge;
    const uint32_t *next;
    size_t remaining;
    unsigned chunk;
    int rows, calls;
} Stream;

static int more(SpiceSwiftQuicUsrContext *user, uint32_t **out, int rows) {
    Stream *s = (Stream *)user;
    if (rows < s->rows) abort();
    s->rows = rows;
    s->calls++;
    size_t n = s->remaining < s->chunk ? s->remaining : s->chunk;
    *out = (uint32_t *)s->next;
    s->next += n;
    s->remaining -= n;
    return (int)n;
}

int audit_native_decode(const uint32_t *input, size_t size, unsigned chunk,
                        int target, uint8_t *output, int stride, int *meta) {
    Stream s = {0};
    s.bridge.usr = (SpiceSwiftQuicUsrContext) {
        spice_swift_quic_error, spice_swift_quic_warn, spice_swift_quic_info,
        spice_swift_quic_malloc, spice_swift_quic_free, more, spice_swift_quic_more_lines
    };
    SpiceSwiftQuicContext *context = quic_create(&s.bridge.usr);
    if (!context) return -1;
    if (setjmp(s.bridge.jump)) { quic_destroy(context); return -1; }
    unsigned n = size / 4 < chunk ? (unsigned)(size / 4) : chunk;
    s.next = input + n;
    s.remaining = size / 4 - n;
    s.chunk = chunk;
    SpiceSwiftQuicImageType kind;
    int width, height;
    int status = quic_decode_begin(context, (uint32_t *)input, n, &kind, &width, &height);
    if (status == 0) {
        meta[0] = kind; meta[1] = width; meta[2] = height;
        if (stride < 0) output += (size_t)(height - 1) * (size_t)(-(int64_t)stride);
        status = quic_decode(context, target, output, stride);
    }
    quic_destroy(context);
    return status;
}
