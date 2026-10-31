#ifndef SPICE_ZIG_NETWORK_BRIDGE_H
#define SPICE_ZIG_NETWORK_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
typedef void (*SpiceNWState)(void *, int, int, int);
typedef int (*SpiceNWVerify)(void *, void *);
typedef void (*SpiceNWRelease)(void *);
typedef void (*SpiceNWComplete)(void *, size_t, int, int, int);
/* Takes ownership of exactly one verify_context reference, even on failure.
 * State context must live through cancel + cancelled callback + destroy.
 * Verify context is independent and may live beyond connection cancellation. */
void *spice_nw_create(const char *, const char *, int, const char *,
                     SpiceNWState, void *, SpiceNWVerify, void *, SpiceNWRelease);
void spice_nw_start(void *);
void spice_nw_cancel(void *);
/* Caller must join outstanding read/write calls before destroy. Never call
 * destroy from a native callback. Clears and drains the state callback queue. */
void spice_nw_destroy(void *);
void spice_nw_read(void *, uint8_t *, uint32_t, uint32_t, SpiceNWComplete, void *);
int spice_nw_write(void *, const uint8_t *, size_t, SpiceNWComplete, void *);
int spice_sec_certificate_valid(const uint8_t *, size_t);
typedef struct { const uint8_t *data; size_t size; } SpiceDER;
/* mode 2 modern custom CA, 3 legacy basic-X509. Trust and strings borrowed. */
int spice_sec_evaluate(void *, int, const SpiceDER *, size_t, const char *);
int spice_sec_subject(void *, int (*)(void *, const uint8_t *, size_t), void *);
#endif
