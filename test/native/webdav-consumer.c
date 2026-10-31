#include "spice_zig_webdav.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
struct Client { SpiceZigDesktop *desktop; SpiceZigWebDAV *server; _Atomic int stopping; };
static void *receive(void *raw) {
    struct Client *self=raw;
    while(!atomic_load(&self->stopping)) {
        SpiceZigDesktopEvent *event=NULL;
        int result=spice_zig_desktop_next(self->desktop,&event);
        if(atomic_load(&self->stopping)){spice_zig_desktop_event_destroy(event);break;}
        assert(result==1);
        SpiceZigDesktopEventMetadata info;
        assert(!spice_zig_desktop_event_metadata(event,&info));
        assert(info.kind!=2 && info.kind!=3);
        assert(!spice_zig_webdav_observe(self->server,event));
        if(info.kind==6 && info.detail==6){puts("migrated");fflush(stdout);}
        spice_zig_desktop_event_destroy(event);
    }
    return NULL;
}
int main(int argc,char **argv) {
    assert(argc==4);struct Client self={0};
    assert(!spice_zig_desktop_create(NULL,0,&self.desktop));
    const uint8_t secret[]="synthetic-test";
    assert(!spice_zig_desktop_connect(self.desktop,"127.0.0.1",(uint16_t)strtoul(argv[1],NULL,10),0,NULL,NULL,NULL,0,3000,secret,sizeof(secret)-1));
    SpiceZigWebDAVOptions options;spice_zig_webdav_options(&options);
    assert(!options.read_write && options.maximum_jobs==64 && options.filesystem_parallelism==2);
    SpiceZigWebDAV *invalid=(void *)1;options.maximum_jobs=0;
    assert(spice_zig_webdav_create(self.desktop,(const uint8_t *)argv[2],strlen(argv[2]),&options,&invalid)==-51 && !invalid);
    options.maximum_jobs=8;options.read_write=(uint8_t)atoi(argv[3]);
    assert(!spice_zig_webdav_create(self.desktop,(const uint8_t *)argv[2],strlen(argv[2]),&options,&self.server));
    pthread_t thread;assert(!pthread_create(&thread,NULL,receive,&self));
    puts("ready");fflush(stdout);
    char input[64];
    while(fgets(input,sizeof(input),stdin)) {
        if(!strcmp(input,"stop\n"))break;
        unsigned expected=0;int buffered=sscanf(input,"buffered %u",&expected)==1;
        assert(buffered || sscanf(input,"completed %u",&expected)==1);
        SpiceZigWebDAVDiagnostics d={0};
        for(unsigned attempt=0;attempt<5000;attempt++) {
            assert(!spice_zig_webdav_diagnostics(self.server,&d));
            const char *error=NULL;int status=spice_zig_webdav_status(self.server,&error);
            if(status){fprintf(stderr,"unexpected status %d %s\n",status,error?error:"");abort();}
            if((buffered?d.buffered_bytes:d.completed)>=expected)break;
            usleep(1000);
        }
        assert((buffered?d.buffered_bytes:d.completed)==expected && d.pending_jobs==0 && d.pending_bytes==0 && d.reserved_bytes==0);
        puts(buffered?"buffered":"completed");fflush(stdout);
    }
    atomic_store(&self.stopping,1);
    spice_zig_desktop_cancel(self.desktop);
    assert(!pthread_join(thread,NULL));
    spice_zig_webdav_stop(self.server);
    for(unsigned attempt=0;attempt<5000 && spice_zig_webdav_status(self.server,NULL)==0;attempt++)usleep(1000);
    assert(spice_zig_webdav_status(self.server,NULL)==1);
    SpiceZigWebDAVDiagnostics final;assert(!spice_zig_webdav_diagnostics(self.server,&final));
    assert(!final.clients && !final.buffered_bytes && !final.pending_jobs && !final.pending_bytes && !final.reserved_bytes);
    spice_zig_webdav_destroy(self.server);spice_zig_desktop_destroy(self.desktop);
    puts("public WebDAV executor lifecycle passed");
    return 0;
}
