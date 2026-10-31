#include "spice_zig.h"
#include <assert.h>
#include <string.h>

int main(void) {
    const uint8_t input[] = {103,0,3,0,0,0, 0xa1,0xa2,0xa3};
    spice_zig_wire_destroy(NULL);
    spice_zig_batch_destroy(NULL);
    assert(spice_zig_wire_create(2, 64, 128, 8) == NULL);
    assert(spice_zig_wire_append(NULL, NULL, 0) == -1);
    for (size_t split=0; split<=sizeof(input); split++) {
        SpiceZigWire *wire = spice_zig_wire_create(1, 64, 128, 8);
        assert(wire);
        assert(spice_zig_wire_append(wire, NULL, 1) == -1);
        assert(spice_zig_wire_append(wire, NULL, 0) == 0);
        assert(spice_zig_wire_append(wire, input, split) == 0);
        SpiceZigBatch *batch = NULL;
        if (split < sizeof(input)) {
            assert(spice_zig_wire_next(wire, 4096, &batch) == 0);
            assert(batch == NULL);
        }
        assert(spice_zig_wire_append(wire, input+split, sizeof(input)-split) == 0);
        assert(spice_zig_wire_next(wire, 4096, &batch) == 1);
        assert(spice_zig_wire_buffered(wire) == 0);
        assert(spice_zig_batch_count(batch) == 1);
        uint64_t serial = 42;
        assert(spice_zig_batch_serial(batch, &serial) == 0 && serial == 42);
        spice_zig_wire_reset(wire);
        spice_zig_wire_destroy(wire);
        uint16_t type = 0;
        const uint8_t *body = NULL;
        size_t size = 0;
        assert(spice_zig_batch_message(batch, 1, &type, &body, &size) == -1);
        assert(spice_zig_batch_message(batch, 0, &type, &body, &size) == 0);
        assert(type == 103 && size == 3 && memcmp(body, input+6, 3) == 0);
        spice_zig_batch_destroy(batch);
    }
    const uint8_t lz[] = {0x20,0x20,0x5a,0x4c,0,1,0,1,0,0,0,11,
        0,0,0,1,0,0,0,1,0,0,0,1,0,0,0,1,0,42};
    SpiceZigImage *image = NULL;
    assert(spice_zig_lz_decode(lz, sizeof(lz), 1, 1, NULL, 0, &image) == 0);
    assert(image && spice_zig_image_flags(image) == 3);
    size_t size = 0;
    const uint8_t *pixels = spice_zig_image_data(image, &size);
    assert(size == 4 && pixels[0] == 0 && pixels[1] == 0 && pixels[2] == 0 && pixels[3] == 42);
    spice_zig_image_destroy(image);
    for (size_t end=0; end<sizeof(lz); end++) {
        assert(spice_zig_lz_decode(lz, end, 1, 1, NULL, 0, &image) < 0);
        assert(image == NULL);
    }
    spice_zig_image_destroy(NULL);
    return 0;
}
