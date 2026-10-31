#include "spice_zig_agent.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
_Static_assert(sizeof(SpiceZigAgentOptions)==48,"options ABI");
_Static_assert(sizeof(SpiceZigAgentEventInfo)==72,"event ABI");
_Static_assert(sizeof(SpiceZigFileKey)==16,"file key ABI");
struct Client {SpiceZigAgentManager *manager;const char *path;SpiceZigFileKey first,second;SpiceZigAgentEvent *text,*name;unsigned flags,writes;int queued,second_queued,layout,switch_host;};
static int write_text(void *p,const uint8_t *bytes,size_t size,int64_t *change,SpiceZigDesktopSendToken *token){
    struct Client *self=p;assert(!spice_zig_agent_token_cancelled(token));assert(size==5 && !memcmp(bytes,"guest",5));self->writes++;*change=3;return 0;
}
static void queue_file(struct Client *self,SpiceZigFileKey *out){const uint8_t name[]="fixture.bin";assert(!spice_zig_agent_manager_send_file(self->manager,(const uint8_t *)self->path,strlen(self->path),name,sizeof(name)-1,out));assert(out->id && out->incarnation);}
static void drain(struct Client *self){
    SpiceZigAgentEvent *event=NULL;int status;
    while((status=spice_zig_agent_manager_next(self->manager,&event))==1){
        SpiceZigAgentEventInfo info;assert(!spice_zig_agent_event_info(event,&info));
        if(info.kind==1 && info.detail==3){assert(!self->text);self->text=event;event=NULL;self->flags|=1;assert(!spice_zig_agent_manager_enable_clipboard(self->manager,0));}
        if(info.kind==2 && (info.values[0]&(1<<6)) && !self->queued){self->queued=1;queue_file(self,&self->first);}
        if(info.kind==3 && info.detail==3){
            SpiceZigRequestedMonitor monitor;assert(!spice_zig_agent_event_monitor(event,0,&monitor));
            if(!self->layout){self->layout=1;SpiceZigRequestedMonitor next={2,-20,50,800,600};assert(!spice_zig_agent_manager_request_display(self->manager,&next,1));}
            else {assert(monitor.id==2 && monitor.x==-20 && monitor.width==800);self->flags|=2;}
        }
        if(info.kind==4){
            if(info.detail==1 && !self->name){self->name=event;event=NULL;}
            if(info.detail==4 && info.values[0]==self->first.id){self->flags|=4;self->second_queued=1;queue_file(self,&self->second);}
            if(info.detail==2 && self->second_queued && info.values[0]==self->second.id)assert(!spice_zig_agent_manager_cancel_file(self->manager,self->second));
            if(info.detail==5 && self->second_queued && info.values[0]==self->second.id)self->flags|=8;
            if(info.detail==6){if(self->switch_host && info.values[0]==self->first.id && !strcmp(spice_zig_agent_event_error(event),"AgentUnavailable"))self->flags|=12;else{fprintf(stderr,"agent file failure: %s\n",spice_zig_agent_event_error(event));abort();}}
        }
        if(info.kind==3 && info.detail>=5){fprintf(stderr,"agent display failure\n");abort();}
        spice_zig_agent_event_destroy(event);event=NULL;
    }
    assert(status==0);
}
static void pump(struct Client *self,SpiceZigDesktopSendToken *token){
    for(unsigned i=0;i<128;i++){int status=spice_zig_agent_manager_pump(self->manager,token,8);assert(status>=0);drain(self);if(status==1)return;if(status==0){int follow=spice_zig_agent_manager_pump(self->manager,token,1);assert(follow>=0);drain(self);if(follow!=2)return;}}
    abort();
}
int main(int argc,char **argv){
    assert(argc==4);SpiceZigDesktop *desktop=NULL;assert(!spice_zig_desktop_create(NULL,0,&desktop));const uint8_t secret[]="synthetic-test";
    assert(!spice_zig_desktop_connect(desktop,"127.0.0.1",(uint16_t)strtoul(argv[1],NULL,10),0,NULL,NULL,NULL,0,3000,secret,sizeof(secret)-1));
    SpiceZigDesktopInfo bootstrap;assert(!spice_zig_desktop_info(desktop,&bootstrap));SpiceZigAgentOptions options;spice_zig_agent_options(&options);
    struct Client self={.path=argv[2],.switch_host=atoi(argv[3])};assert(!spice_zig_agent_manager_create(desktop,&options,write_text,&self,&self.manager));SpiceZigDesktopSendToken *token=spice_zig_desktop_send_token_create();assert(token);
    const uint8_t local[]="host";assert(!spice_zig_agent_manager_local_text(self.manager,1,1,local,sizeof(local)-1));SpiceZigRequestedMonitor initial={0,0,0,640,480};assert(!spice_zig_agent_manager_request_display(self.manager,&initial,1));drain(&self);pump(&self,token);puts("ready");fflush(stdout);
    while(self.flags!=63){
        SpiceZigDesktopEvent *event=NULL;assert(spice_zig_desktop_next(desktop,&event)==1);SpiceZigDesktopEventMetadata info;assert(!spice_zig_desktop_event_metadata(event,&info));assert(info.kind!=2 && info.kind!=3);
        assert(!spice_zig_agent_manager_observe(self.manager,event));
        if(info.kind==6 && info.detail==6){self.flags|=16;if(self.switch_host){SpiceZigDesktopInfo fresh;assert(!spice_zig_desktop_info(desktop,&fresh));assert(fresh.lifecycle>bootstrap.lifecycle && fresh.agent_epoch==bootstrap.agent_epoch);assert(spice_zig_desktop_agent_at(desktop,bootstrap.lifecycle,bootstrap.agent_epoch,1,4,0,NULL,0,token)==-45);}puts("migrated");fflush(stdout);}
        if(info.kind==4 && info.detail==2){
            assert(info.wide[2]==bootstrap.lifecycle+(unsigned)self.switch_host && info.wide[1]>bootstrap.agent_epoch);
            assert(spice_zig_desktop_agent_at(desktop,bootstrap.lifecycle,bootstrap.agent_epoch,1,4,0,NULL,0,token)==-45);
            self.flags|=32;
        }
        spice_zig_desktop_event_destroy(event);drain(&self);pump(&self,token);
    }
    assert(self.writes==1 && self.text && self.name);spice_zig_agent_manager_destroy(self.manager);spice_zig_desktop_send_token_destroy(token);spice_zig_desktop_cancel(desktop);spice_zig_desktop_destroy(desktop);
    size_t size=0;const uint8_t *data=spice_zig_agent_event_data(self.text,&size);assert(size==5 && !memcmp(data,"guest",5));data=spice_zig_agent_event_data(self.name,&size);assert(size==11 && !memcmp(data,"fixture.bin",11));spice_zig_agent_event_destroy(self.text);spice_zig_agent_event_destroy(self.name);puts("public Agent manager lifetime migration and file transfer passed");return 0;
}
