#ifndef SPICE_ZIG_USB_H
#define SPICE_ZIG_USB_H
#include "spice_zig_desktop.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Exact native usbredir backend. Creation never selects a physical device.
 * attach=1 opens only the explicitly authorized bus/address after guest filtering;
 * attach=0 detaches. Consumers obtain authorization before selecting hardware.
 * Methods serialize access; destroy releases caller ownership.
 * Joined executors can retain the same host. Join callers before release.
 * Results: 0 success; -100 argument; -101 allocation; -102 native failure
 * (native_code carries its integer code); -103 buffered limit; -104 not found;
 * -105 guest rejected; -106 queue limit; -107 not ready; -108 closed/cancelled.
 * Other failures return -1. Never retry an uncertain USB side effect. */
typedef struct SpiceZigUSBHost SpiceZigUSBHost;
typedef struct { size_t maximum_buffered_bytes,maximum_packet_bytes; } SpiceZigUSBHostOptions;
void spice_zig_usb_host_options(SpiceZigUSBHostOptions *);
int spice_zig_usb_host_create(const SpiceZigUSBHostOptions *,SpiceZigUSBHost **);
void spice_zig_usb_host_destroy(SpiceZigUSBHost *);
/* Atomic standalone operation plus owned packet drain. kind: 0 initial,
 * 1 receive, 2 attach device, 3 detach device, 4 pump. No retries on error. */
typedef struct SpiceZigUSBPackets SpiceZigUSBPackets;
int spice_zig_usb_host_exchange(SpiceZigUSBHost *,uint8_t kind,const uint8_t *,size_t,uint8_t bus,uint8_t address,uint32_t milliseconds,SpiceZigUSBPackets **,int *native_code);
const uint8_t *spice_zig_usb_packets_bytes(const SpiceZigUSBPackets *,size_t *size,size_t *packet_size);
void spice_zig_usb_packets_destroy(SpiceZigUSBPackets *);
int spice_zig_usb_host_receive(SpiceZigUSBHost *,const uint8_t *,size_t,int *native_code);
int spice_zig_usb_host_device(SpiceZigUSBHost *,uint8_t attach,uint8_t bus,uint8_t address,int *native_code);
int spice_zig_usb_host_pump(SpiceZigUSBHost *,uint32_t milliseconds,int *native_code);
/* Copies at most min(capacity,maximum_packet_bytes), consuming only those bytes.
 * Drain until written=0. No allocation is required by take. */
int spice_zig_usb_host_take(SpiceZigUSBHost *,uint8_t *,size_t capacity,size_t *written);
/* Optional joined session executor. This exclusively owns USB traffic for one
 * channel; do not also send raw USB data. Feed ordered Desktop events before
 * releasing them. Same-guest handoff preserves native protocol/device state;
 * switching guests or disconnecting stops this owner and closes its device.
 * Enable a new owner explicitly to serve a new guest. No automatic reselection.
 * Poll status and end the consumer session on terminal worker errors.
 * Cancellation closes a pinned transport only if a write has entered it.
 * Failed entered writes terminate; no automatic replay. Pre-write handoff waits
 * retain exact queued bytes. Queue admission errors are terminal.
 * Destroy BEFORE Desktop, with exclusive access, after joining device callers.
 * device waits for completion: call it off the event-reading thread. stop can
 * interrupt sends, while destroy also waits for entered native USB cleanup.
 * create_shared retains the provided host and preserves its protocol state.
 * Stopping the runner detaches the device even if the caller retains the host. */
typedef struct SpiceZigUSB SpiceZigUSB;
typedef struct { uint8_t channel_id,reserved[7];SpiceZigUSBHostOptions host;size_t maximum_queued_bytes; } SpiceZigUSBOptions;
void spice_zig_usb_options(SpiceZigUSBOptions *);
int spice_zig_usb_create(SpiceZigDesktop *,const SpiceZigUSBOptions *,SpiceZigUSB **);
int spice_zig_usb_create_shared(SpiceZigDesktop *,uint8_t channel_id,SpiceZigUSBHost *,SpiceZigUSB **);
int spice_zig_usb_observe(SpiceZigUSB *,const SpiceZigDesktopEvent *);
int spice_zig_usb_device(SpiceZigUSB *,uint8_t attach,uint8_t bus,uint8_t address,int *native_code);
/* Wait for initial queued output, without changing device selection. */
int spice_zig_usb_ready(SpiceZigUSB *);
void spice_zig_usb_stop(SpiceZigUSB *);
void spice_zig_usb_destroy(SpiceZigUSB *);
/* 0 running; 1 finished; negative failure. category is static and content-free. */
int spice_zig_usb_status(SpiceZigUSB *,const char **error_category,int *native_code);
typedef struct { uint64_t received_bytes,sent_bytes,sent_packets,queued_bytes; } SpiceZigUSBStatistics;
int spice_zig_usb_statistics(SpiceZigUSB *,SpiceZigUSBStatistics *);
/* Route borrows runners through detach, which joins observations. No replay of
 * packets preceding attachment. observe returns 1 for handled USB packets,
 * 0 otherwise, negative on failure. Attach requires a ready matching channel;
 * -109 means already attached. Destroy routes only after detaching all runners. */
typedef struct SpiceZigUSBRoute SpiceZigUSBRoute;
int spice_zig_usb_route_create(SpiceZigUSBRoute **);
void spice_zig_usb_route_destroy(SpiceZigUSBRoute *);
int spice_zig_usb_route_observe(SpiceZigUSBRoute *,const SpiceZigDesktopEvent *);
int spice_zig_usb_route_attach(SpiceZigUSBRoute *,SpiceZigDesktop *,SpiceZigUSB *);
void spice_zig_usb_route_detach(SpiceZigUSBRoute *,SpiceZigUSB *);
#ifdef __cplusplus
}
#endif
#endif
