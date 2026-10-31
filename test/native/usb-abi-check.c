#include <stddef.h>
#include <sys/time.h>
size_t spice_usb_test_timeval_size(void) { return sizeof(struct timeval); }
size_t spice_usb_test_timeval_usec_offset(void) { return offsetof(struct timeval, tv_usec); }
