// Test input generation only; never a dependency of the pure Swift decoder.
#include "QUICReference.h"
#ifdef QUIC_REFERENCE_PREFIXED
#define quic_create oracle_quic_create
#define quic_destroy oracle_quic_destroy
#define quic_encode oracle_quic_encode
#define quic_decode_begin oracle_quic_decode_begin
#define quic_decode oracle_quic_decode
#endif
// Textual source include: framework Clang modules would ignore the oracle
// symbol-renaming macros above when loading their precompiled header.
#include "../../../pkg/quic/shim.h"

int quic_encode(SpiceSwiftQuicContext *, SpiceSwiftQuicImageType, int, int,
                uint8_t *, unsigned int, int, uint32_t *, unsigned int);

int quic_reference_encode(int type, int width, int height, const uint8_t *bgra,
                          size_t input_size, uint8_t **encoded, size_t *encoded_size) {
    if (!encoded || !encoded_size) return 1;
    *encoded = NULL;
    *encoded_size = 0;
    if (!bgra || type < 1 || type > 5 || width < 1 || height < 1) return 1;
    size_t pixels = (size_t)width * (size_t)height;
    if (pixels > 16 * 1024 * 1024 || input_size != pixels * 4) return 1;
    int components = type == 1 ? 1 : type == 2 ? 2 : type == 3 ? 3 : 4;
    uint8_t *input = malloc(pixels * (size_t)components);
    size_t capacity = pixels * 16 + 1024;
    uint32_t *output = calloc(capacity / 4, sizeof(uint32_t));
    if (!input || !output) { free(input); free(output); return 1; }
    for (size_t i = 0; i < pixels; ++i) {
        const uint8_t *p = bgra + i * 4;
        uint8_t *q = input + i * (size_t)components;
        if (type == 1) {
            q[0] = p[0];
        } else if (type == 2) {
            uint16_t packed = (uint16_t)((p[2] >> 3) << 10 | (p[1] >> 3) << 5 | (p[0] >> 3));
            memcpy(q, &packed, sizeof(packed));
        } else {
            memcpy(q, p, (size_t)components);
        }
    }
    SpiceSwiftQuicBridge bridge = {0};
    bridge.usr.error = spice_swift_quic_error;
    bridge.usr.warn = spice_swift_quic_warn;
    bridge.usr.info = spice_swift_quic_info;
    bridge.usr.malloc = spice_swift_quic_malloc;
    bridge.usr.free = spice_swift_quic_free;
    bridge.usr.more_space = spice_swift_quic_more_space;
    bridge.usr.more_lines = spice_swift_quic_more_lines;
    SpiceSwiftQuicContext *context = quic_create(&bridge.usr);
    if (!context) { free(input); free(output); return 1; }
    // The non-local error path stays entirely inside C; all owned allocations
    // and context are established before setjmp and cleaned on both paths.
    if (setjmp(bridge.jump)) {
        quic_destroy(context); free(input); free(output); return 1;
    }
    int words = quic_encode(context, (SpiceSwiftQuicImageType)type, width, height,
                            input, (unsigned int)height, width * components,
                            output, (unsigned int)(capacity / 4));
    quic_destroy(context);
    free(input);
    if (words <= 0 || bridge.warned) { free(output); return 1; }
    *encoded = (uint8_t *)output;
    *encoded_size = (size_t)words * 4;
    return 0;
}

int quic_reference_decode(const uint8_t *input, size_t size, int width, int height,
                           uint8_t *output, size_t output_size) {
    int kind, decoded_width, decoded_height;
    return spice_swift_quic_decode(input, size, width, height, output, output_size,
                                   &kind, &decoded_width, &decoded_height);
}
