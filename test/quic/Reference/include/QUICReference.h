#ifndef QUIC_EXPERIMENT_REFERENCE_H
#define QUIC_EXPERIMENT_REFERENCE_H
#include <stddef.h>
#include <stdint.h>

// Test oracle only. The caller owns *encoded and must release it with free().
int quic_reference_encode(int type, int width, int height, const uint8_t *bgra,
                          size_t input_size, uint8_t **encoded, size_t *encoded_size);
int quic_reference_decode(const uint8_t *input, size_t size, int width, int height,
                           uint8_t *output, size_t output_size);
#endif
