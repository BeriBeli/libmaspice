#include "spice_zig_usb.h"
#include "CUSBRedirShim.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(void) {
    SpiceZigUSBHostOptions opts;spice_zig_usb_host_options(&opts);
    assert(opts.maximum_buffered_bytes==16*1024*1024 && opts.maximum_packet_bytes==1024*1024);
    SpiceZigUSBHost *bad=(void *)1;opts.maximum_buffered_bytes=0;
    assert(spice_zig_usb_host_create(&opts,&bad)==-100 && !bad);
    opts.maximum_buffered_bytes=4096;opts.maximum_packet_bytes=8;
    for(unsigned cycle=0;cycle<64;cycle++) {
        SpiceZigUSBHost *host=NULL;assert(!spice_zig_usb_host_create(&opts,&host));
        SpiceUSBRedirHostContext *oracle=spice_usbredir_host_create(4096);assert(oracle);
        uint8_t hello[4096],chunk[64],reference[64];size_t total=0,written=99;
        do {
            memset(chunk,0xa7,sizeof(chunk));assert(!spice_zig_usb_host_take(host,chunk,9,&written));
            assert(written<=8 && chunk[written]==0xa7);
            size_t expected=spice_usbredir_host_take_output(oracle,reference,written?written:8);
            assert(written==expected && !memcmp(chunk,reference,written));
            assert(total+written<sizeof(hello));memcpy(hello+total,chunk,written);total+=written;
        }while(written);
        assert(total>32);
        int code=99;
        assert(spice_zig_usb_host_receive(host,NULL,0,&code)==-100 && code==0);
        assert(spice_zig_usb_host_pump(host,101,&code)==-100);
        assert(spice_zig_usb_host_device(host,1,255,255,&code)==-104 && code==0);
        for(size_t i=0;i<total;i++) {
            int result=spice_zig_usb_host_receive(host,hello+i,1,&code);
            int expected=spice_usbredir_host_feed_guest(oracle,hello+i,1);
            assert((result==0 && expected==0) || (result==-102 && code==expected));
        }
        assert(!spice_zig_usb_host_pump(host,0,&code));
        assert(!spice_usbredir_host_pump(oracle,0));
        do {
            assert(!spice_zig_usb_host_take(host,chunk,sizeof(chunk),&written));
            size_t expected=spice_usbredir_host_take_output(oracle,reference,written?written:8);
            assert(written==expected && !memcmp(chunk,reference,written));
        }while(written);
        assert(!spice_zig_usb_host_device(host,0,0,0,&code));
        spice_zig_usb_host_destroy(host);spice_usbredir_host_destroy(oracle);
    }
    SpiceZigUSBHost *host=NULL;assert(!spice_zig_usb_host_create(&opts,&host));
    SpiceZigUSBPackets *packets=NULL;int native=0;
    assert(!spice_zig_usb_host_exchange(host,0,NULL,0,0,0,0,&packets,&native));
    spice_zig_usb_host_destroy(host);
    size_t length=0,maximum=0;
    const uint8_t *bytes=spice_zig_usb_packets_bytes(packets,&length,&maximum);
    assert(bytes && length==80 && maximum==8 && bytes[0]==0);
    spice_zig_usb_packets_destroy(packets);
    puts("64 public USB host native oracle/sanitizer lifecycle checks passed");return 0;
}
