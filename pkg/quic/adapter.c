// SPDX-License-Identifier: LGPL-2.1-or-later
// This boundary contains no codec algorithm. Fatal user callbacks are invoked
// only after Zig has returned and released every per-operation allocation.
#include "quic.h"
#include <stddef.h>

extern void *spice_quic_zig_create(QuicUsrContext *);
extern void spice_quic_zig_destroy(void *);
extern QuicUsrContext *spice_quic_zig_user(void *);
extern int spice_quic_zig_encode(void *, int, int, int, uint8_t *, unsigned, int, uint32_t *, unsigned);
extern int spice_quic_zig_begin(void *, uint32_t *, unsigned, int *, int *, int *);
extern int spice_quic_zig_decode(void *, int, uint8_t *, int);

static int report(QuicContext *context, int result) {
    if (result >= 0) return result;
    QuicUsrContext *usr = spice_quic_zig_user(context);
    if (result == -2) {
        usr->error(usr, "invalid QUIC stream or failed I/O callback\n");
    }
    if (result == -1) usr->warn(usr, "invalid QUIC argument or unsupported format\n");
    // -3 is an allocation failure, matching upstream's QUIC_ERROR return.
    return QUIC_ERROR;
}

QuicContext *quic_create(QuicUsrContext *usr) {
    if (!usr || !usr->error || !usr->warn || !usr->info || !usr->malloc ||
        !usr->free || !usr->more_space || !usr->more_lines) return NULL;
    return spice_quic_zig_create(usr);
}
void quic_destroy(QuicContext *context) { if (context) spice_quic_zig_destroy(context); }
int quic_encode(QuicContext *context, QuicImageType type, int width, int height,
                uint8_t *lines, unsigned num_lines, int stride,
                uint32_t *output, unsigned words) {
    if (!context) return QUIC_ERROR;
    return report(context, spice_quic_zig_encode(context, type, width, height, lines, num_lines,
                                     stride, output, words));
}
int quic_decode_begin(QuicContext *context, uint32_t *input, unsigned words,
                      QuicImageType *type, int *width, int *height) {
    if (!context) return QUIC_ERROR;
    int kind;
    if (!type || !width || !height) return report(context, -1);
    int status = spice_quic_zig_begin(context, input, words, &kind, width, height);
    if (status == 0) *type = (QuicImageType)kind;
    return report(context, status);
}
int quic_decode(QuicContext *context, QuicImageType type, uint8_t *output, int stride) {
    if (!context) return QUIC_ERROR;
    return report(context, spice_quic_zig_decode(context, type, output, stride));
}
