#import <AppKit/AppKit.h>
#include "spice_zig_agent.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
struct Client {SpiceZigDesktop *desktop;SpiceZigAgentRunner *runner;SpiceZigDesktopInfo bootstrap;const char *path;SpiceZigFileKey first,second;SpiceZigAgentRunnerEvent *text,*name;_Atomic unsigned flags;_Atomic int stopping;int queued,second_queued,layout,switch_host;};
static void queue_file(struct Client *self,uint64_t request){const uint8_t name[]="fixture.bin";assert(!spice_zig_agent_runner_send_file(self->runner,request,(const uint8_t *)self->path,strlen(self->path),name,sizeof(name)-1));}
static void drain(struct Client *self){
    SpiceZigAgentRunnerEvent *owned=NULL;int status;
    while((status=spice_zig_agent_runner_next(self->runner,&owned))==1){
        SpiceZigAgentRunnerEventInfo out;assert(!spice_zig_agent_runner_event_info(owned,&out));
        if(out.kind==2){fprintf(stderr,"runner failure: %s\n",spice_zig_agent_runner_event_error(owned));abort();}
        if(out.kind==3){assert(out.request==1 || out.request==2);assert(out.key.id && out.key.incarnation);if(out.request==1)self->first=out.key;else self->second=out.key;}
        const SpiceZigAgentEvent *event=spice_zig_agent_runner_event_agent(owned);
        if(event){
            SpiceZigAgentEventInfo info;assert(!spice_zig_agent_event_info(event,&info));
            if(info.kind==1 && info.detail==3){assert(!self->text);self->text=owned;owned=NULL;atomic_fetch_or(&self->flags,1);assert(!spice_zig_agent_runner_enable_clipboard(self->runner,0));}
            if(info.kind==2 && (info.values[0]&3)==3 && (atomic_load(&self->flags)&32))atomic_fetch_or(&self->flags,64);
            if(info.kind==2 && (info.values[0]&(1<<6)) && !self->queued){self->queued=1;queue_file(self,1);}
            if(info.kind==3 && info.detail==3){SpiceZigRequestedMonitor monitor;assert(!spice_zig_agent_event_monitor(event,0,&monitor));if(!self->layout){self->layout=1;SpiceZigRequestedMonitor next={2,-20,50,800,600};assert(!spice_zig_agent_runner_request_display(self->runner,2,&next,1));}else{assert(monitor.id==2 && monitor.x==-20 && monitor.width==800);atomic_fetch_or(&self->flags,2);}}
            if(info.kind==4){
                if(info.detail==1 && !self->name){self->name=owned;owned=NULL;}
                if(info.detail==4 && info.values[0]==self->first.id){atomic_fetch_or(&self->flags,4);self->second_queued=1;queue_file(self,2);}
                if(info.detail==2 && self->second_queued && info.values[0]==self->second.id)assert(!spice_zig_agent_runner_cancel_file(self->runner,3,self->second));
                if(info.detail==5 && self->second_queued && info.values[0]==self->second.id)atomic_fetch_or(&self->flags,8);
                if(info.detail==6){if(self->switch_host && info.values[0]==self->first.id && !strcmp(spice_zig_agent_event_error(event),"AgentUnavailable"))atomic_fetch_or(&self->flags,12);else{fprintf(stderr,"file failure: %s\n",spice_zig_agent_event_error(event));abort();}}
            }
            assert(info.kind!=3 || info.detail<5);
        }
        spice_zig_agent_runner_event_destroy(owned);owned=NULL;
    }
    assert(!status && spice_zig_agent_runner_status(self->runner)==0);
}
static void *receive(void *p){struct Client *self=p;@autoreleasepool{
    SpiceZigDesktopSendToken *token=spice_zig_desktop_send_token_create();assert(token);
    while(!atomic_load(&self->stopping)){
        SpiceZigDesktopEvent *event=NULL;int status=spice_zig_desktop_next(self->desktop,&event);if(atomic_load(&self->stopping)){spice_zig_desktop_event_destroy(event);break;}assert(status==1);
        SpiceZigDesktopEventMetadata info;assert(!spice_zig_desktop_event_metadata(event,&info));assert(info.kind!=2 && info.kind!=3);assert(!spice_zig_agent_runner_observe(self->runner,event));
        if(info.kind==6 && info.detail==6){atomic_fetch_or(&self->flags,16);if(self->switch_host){SpiceZigDesktopInfo fresh;assert(!spice_zig_desktop_info(self->desktop,&fresh));assert(fresh.lifecycle>self->bootstrap.lifecycle && fresh.agent_epoch==self->bootstrap.agent_epoch);assert(spice_zig_desktop_agent_at(self->desktop,self->bootstrap.lifecycle,self->bootstrap.agent_epoch,1,4,0,NULL,0,token)==-45);}puts("migrated");fflush(stdout);}
        if(info.kind==4 && info.detail==2){assert(info.wide[2]==self->bootstrap.lifecycle+(unsigned)self->switch_host && info.wide[1]>self->bootstrap.agent_epoch);assert(spice_zig_desktop_agent_at(self->desktop,self->bootstrap.lifecycle,self->bootstrap.agent_epoch,1,4,0,NULL,0,token)==-45);atomic_fetch_or(&self->flags,32);}
        spice_zig_desktop_event_destroy(event);
    }
    spice_zig_desktop_send_token_destroy(token);
}return NULL;}
int main(int argc,char **argv){@autoreleasepool{
    assert(argc==4);struct Client self={.path=argv[2],.switch_host=atoi(argv[3])};assert(!spice_zig_desktop_create(NULL,0,&self.desktop));const uint8_t secret[]="synthetic-test";
    assert(!spice_zig_desktop_connect(self.desktop,"127.0.0.1",(uint16_t)strtoul(argv[1],NULL,10),0,NULL,NULL,NULL,0,3000,secret,sizeof(secret)-1));assert(!spice_zig_desktop_info(self.desktop,&self.bootstrap));
    NSPasteboard *board=[NSPasteboard pasteboardWithUniqueName];[board clearContents];assert([board setString:@"host" forType:NSPasteboardTypeString]);NSData *name=[board.name dataUsingEncoding:NSUTF8StringEncoding];
    SpiceZigAgentOptions options;spice_zig_agent_options(&options);assert(!spice_zig_agent_runner_create(self.desktop,&options,name.bytes,name.length,0,10,&self.runner));
    SpiceZigRequestedMonitor initial={0,0,0,640,480};assert(!spice_zig_agent_runner_request_display(self.runner,1,&initial,1));
    pthread_t reader;assert(!pthread_create(&reader,NULL,receive,&self));puts("ready");fflush(stdout);
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20];
    while(atomic_load(&self.flags)!=127){assert(deadline.timeIntervalSinceNow>0);[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.005]];drain(&self);}
    assert(self.text && self.name && [[board stringForType:NSPasteboardTypeString]isEqualToString:@"guest"]);
    atomic_store(&self.stopping,1);spice_zig_agent_runner_stop(self.runner);spice_zig_desktop_cancel(self.desktop);assert(!pthread_join(reader,NULL));spice_zig_agent_runner_destroy(self.runner);spice_zig_desktop_destroy(self.desktop);
    size_t size=0;const uint8_t *data=spice_zig_agent_event_data(spice_zig_agent_runner_event_agent(self.text),&size);assert(size==5 && !memcmp(data,"guest",5));data=spice_zig_agent_event_data(spice_zig_agent_runner_event_agent(self.name),&size);assert(size==11 && !memcmp(data,"fixture.bin",11));spice_zig_agent_runner_event_destroy(self.text);spice_zig_agent_runner_event_destroy(self.name);[board releaseGlobally];puts("public Agent manager lifetime migration and file transfer passed");
}return 0;}
