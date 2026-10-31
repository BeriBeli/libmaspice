/* Test-only native replacements. No libusb calls reach hardware. Real headers
 * check the ABI; counters observe resource ownership across native failures. */
#include <CUSBRedir/usbredirhost.h>
#include <stdlib.h>
#include <string.h>
struct libusb_context { int unused; };
struct libusb_device { int unused; };
struct libusb_device_handle { int unused; };
struct usbredirhost { usbredirparser_read read; usbredirparser_write write; void *owner; libusb_device_handle *device; };
static int mode, contexts, hosts, handles, lists;
static struct libusb_device device;
void spice_usb_fault_mode(int value) { mode = value; }
int spice_usb_fault_live(void) { return contexts + hosts + handles + lists; }
int libusb_init(libusb_context **out) {
    if (mode == 1) return LIBUSB_ERROR_ACCESS;
    *out = calloc(1, sizeof(**out)); if (!*out) return LIBUSB_ERROR_NO_MEM;
    contexts++; return 0;
}
void libusb_exit(libusb_context *context) { free(context); contexts--; }
struct usbredirhost *usbredirhost_open(libusb_context *context, libusb_device_handle *handle,
    usbredirparser_log log, usbredirparser_read read, usbredirparser_write write,
    void *owner, const char *version, int verbose, int flags) {
    (void)context; (void)handle; (void)log; (void)version; (void)verbose; (void)flags;
    uint8_t hello[2] = {'H','I'};
    /* Exercise callbacks before returning, including the failed-open path. */
    (void)write(owner, hello, 2);
    if (mode == 2) return NULL;
    struct usbredirhost *host = calloc(1,sizeof(*host));
    if (!host) return NULL;
    host->read=read; host->write=write; host->owner=owner; hosts++; return host;
}
int usbredirhost_set_device(struct usbredirhost *host, libusb_device_handle *handle) {
    if (host->device) { free(host->device); handles--; host->device=NULL; }
    if (mode == 6 && handle) { free(handle); handles--; return 3; }
    host->device=handle; return 0;
}
void usbredirhost_close(struct usbredirhost *host) {
    (void)usbredirhost_set_device(host,NULL); free(host); hosts--;
}
ssize_t libusb_get_device_list(libusb_context *context, libusb_device ***out) {
    (void)context;
    if (mode == 3) return LIBUSB_ERROR_IO;
    *out=calloc(2,sizeof(**out)); if (!*out) return LIBUSB_ERROR_NO_MEM;
    (*out)[0]=&device; lists++; return 1;
}
void libusb_free_device_list(libusb_device **list,int unref) { (void)unref; free(list); lists--; }
uint8_t libusb_get_bus_number(libusb_device *dev) { (void)dev; return 7; }
uint8_t libusb_get_device_address(libusb_device *dev) { (void)dev; return 9; }
int libusb_open(libusb_device *dev,libusb_device_handle **out) {
    (void)dev; if (mode==5) return LIBUSB_ERROR_ACCESS;
    *out=calloc(1,sizeof(**out)); if (!*out) return LIBUSB_ERROR_NO_MEM;
    handles++; return 0;
}
void usbredirhost_get_guest_filter(struct usbredirhost *host, const struct usbredirfilter_rule **rules,int *count) {
    (void)host; *rules=NULL; *count=mode==4 ? 1 : 0;
}
int usbredirhost_check_device_filter(const struct usbredirfilter_rule *rules,int count,libusb_device *dev,int flags) {
    (void)rules; (void)count; (void)dev; (void)flags; return -1;
}
int usbredirhost_has_data_to_write(struct usbredirhost *host) { (void)host; return mode==7 || mode==8; }
int usbredirhost_write_guest_data(struct usbredirhost *host) {
    uint8_t data[16]={0};
    if (mode==8) return -1;
    return host->write(host->owner,data,16)==16 ? 0 : -1;
}
int usbredirhost_read_guest_data(struct usbredirhost *host) {
    uint8_t data[3];
    while (host->read(host->owner,data,3)>0) {}
    return mode==9 ? -2 : 0;
}
int libusb_handle_events_timeout_completed(libusb_context *context,struct timeval *timeout,int *completed) {
    (void)context; (void)timeout; (void)completed; return mode==10 ? LIBUSB_ERROR_IO : 0;
}
