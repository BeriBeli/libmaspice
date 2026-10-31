#include "spice_zig_usb.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
struct Client { SpiceZigDesktop *desktop;SpiceZigUSB *usb;_Atomic int stopping; };
static void *receive(void *raw) {
    struct Client *self=raw;
    while(!atomic_load(&self->stopping)) {
        SpiceZigDesktopEvent *event=NULL;int result=spice_zig_desktop_next(self->desktop,&event);
        if(atomic_load(&self->stopping)){spice_zig_desktop_event_destroy(event);break;}
        assert(result==1);SpiceZigDesktopEventMetadata info;
        assert(!spice_zig_desktop_event_metadata(event,&info));assert(info.kind!=2 && info.kind!=3);
        int observed=spice_zig_usb_observe(self->usb,event);
        assert(!observed || observed==-108);
        if(info.kind==6 && info.detail==6){puts("migrated");fflush(stdout);}
        spice_zig_desktop_event_destroy(event);
    }return NULL;
}
int main(int argc,char **argv) {
    assert(argc==2);struct Client self={0};
    assert(!spice_zig_desktop_create(NULL,0,&self.desktop));
    const uint8_t secret[]="synthetic-test";
    assert(!spice_zig_desktop_connect(self.desktop,"127.0.0.1",(uint16_t)strtoul(argv[1],NULL,10),0,NULL,NULL,NULL,0,3000,secret,sizeof(secret)-1));
    SpiceZigUSBOptions opts;spice_zig_usb_options(&opts);opts.host.maximum_packet_bytes=8;
    SpiceZigUSB *bad=(void *)1;opts.maximum_queued_bytes=0;
    assert(spice_zig_usb_create(self.desktop,&opts,&bad)==-100 && !bad);opts.maximum_queued_bytes=4096;
    assert(!spice_zig_usb_create(self.desktop,&opts,&self.usb));
    pthread_t thread;assert(!pthread_create(&thread,NULL,receive,&self));puts("ready");fflush(stdout);
    char input[64];
    while(fgets(input,sizeof(input),stdin)) {
        if(!strcmp(input,"stop\n"))break;
        if(!strcmp(input,"finished\n")) {
            for(unsigned n=0;n<5000 && spice_zig_usb_status(self.usb,NULL,NULL)==0;n++)usleep(1000);
            assert(spice_zig_usb_status(self.usb,NULL,NULL)==1);puts("finished");fflush(stdout);continue;
        }
        if(!strcmp(input,"missing\n")) {
            int code=99;assert(spice_zig_usb_device(self.usb,1,255,255,&code)==-104 && !code);
            assert(!spice_zig_usb_device(self.usb,0,0,0,&code));puts("missing");fflush(stdout);continue;
        }
        unsigned expected;assert(sscanf(input,"received %u",&expected)==1);
        SpiceZigUSBStatistics stats={0};
        for(unsigned n=0;n<5000;n++) {
            assert(!spice_zig_usb_statistics(self.usb,&stats));
            const char *category=NULL;int code=0;int status=spice_zig_usb_status(self.usb,&category,&code);
            if(status){fprintf(stderr,"USB status %d native %d %s\n",status,code,category?category:"");abort();}
            if(stats.received_bytes>=expected && !stats.queued_bytes)break;
            usleep(1000);
        }
        assert(stats.received_bytes==expected && !stats.queued_bytes);puts("received");fflush(stdout);
    }
    atomic_store(&self.stopping,1);spice_zig_usb_stop(self.usb);spice_zig_desktop_cancel(self.desktop);
    assert(!pthread_join(thread,NULL));
    for(unsigned n=0;n<5000 && spice_zig_usb_status(self.usb,NULL,NULL)==0;n++)usleep(1000);
    assert(spice_zig_usb_status(self.usb,NULL,NULL)==1);
    SpiceZigUSBStatistics final;assert(!spice_zig_usb_statistics(self.usb,&final));assert(!final.queued_bytes);
    spice_zig_usb_destroy(self.usb);spice_zig_desktop_destroy(self.desktop);
    puts("public USB executor lifecycle passed");return 0;
}
