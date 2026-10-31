/* Native callback lifetimes exercised with ASan/UBSan-instrumented bridge and
 * consumers. Zig itself remains ReleaseSafe, not ASan-instrumented. */
#include "spice_zig.h"
#include <arpa/inet.h>
#include <assert.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <poll.h>
typedef struct { int listener; int tls; int accepted; } Peer;
static void *serve(void *p) {
    Peer *peer=p;
    int client=accept(peer->listener,NULL,NULL); assert(client>=0);
    assert(write(peer->accepted,"a",1)==1);
    char buffer[4096];
    if (!peer->tls) {
        assert(recv(client,buffer,4,MSG_WAITALL)==4);
        assert(memcmp(buffer,"test",4)==0);
        assert(send(client,buffer,4,0)==4);
    }
    while (recv(client,buffer,sizeof(buffer),0)>0) {}
    close(client); return NULL;
}
typedef struct { SpiceZigTransport *transport; int connecting; int result; } Work;
static void *wait_io(void *p) {
    Work *work=p;
    uint8_t byte;
    work->result=work->connecting ? spice_zig_transport_connect(work->transport)
        : spice_zig_transport_read_exact(work->transport,&byte,1);
    return NULL;
}
int main(void) {
    for (int i=0;i<32;i++) {
        int signal_pipe[2]; assert(pipe(signal_pipe)==0);
        Peer peer={.listener=socket(AF_INET,SOCK_STREAM,0),.tls=i%2,.accepted=signal_pipe[1]}; assert(peer.listener>=0);
        struct sockaddr_in address={.sin_len=sizeof(address),.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
        assert(bind(peer.listener,(struct sockaddr *)&address,sizeof(address))==0);
        assert(listen(peer.listener,1)==0);
        socklen_t size=sizeof(address); assert(getsockname(peer.listener,(struct sockaddr *)&address,&size)==0);
        pthread_t server; assert(pthread_create(&server,NULL,serve,&peer)==0);
        SpiceZigTransport *transport=NULL;
        assert(spice_zig_transport_create("127.0.0.1",ntohs(address.sin_port),peer.tls,NULL,NULL,NULL,0,2000,&transport)==0);
        if (!peer.tls) {
            assert(spice_zig_transport_connect(transport)==0);
            uint8_t buffer[4];
            assert(spice_zig_transport_write(transport,(const uint8_t *)"test",4)==0);
            assert(spice_zig_transport_read_exact(transport,buffer,4)==0);
            assert(memcmp(buffer,"test",4)==0);
        }
        struct pollfd signal={.fd=signal_pipe[0],.events=POLLIN};
        assert(poll(&signal,1,3000)==1); char accepted; assert(read(signal_pipe[0],&accepted,1)==1);
        Work work={.transport=transport,.connecting=peer.tls,.result=99};
        pthread_t worker; assert(pthread_create(&worker,NULL,wait_io,&work)==0);
        // Cancellation before or during operation must both release resources.
        spice_zig_transport_cancel(transport); spice_zig_transport_cancel(transport);
        assert(pthread_join(worker,NULL)==0); assert(work.result==-31);
        spice_zig_transport_destroy(transport);
        // The peer has accepted before cancellation; no accept waiter survives.
        shutdown(peer.listener,SHUT_RDWR); close(peer.listener);
        assert(pthread_join(server,NULL)==0); close(signal_pipe[0]); close(signal_pipe[1]);
    }
    for (int i=0;i<32;i++) {
        SpiceZigSession *session=spice_zig_session_create(16); assert(session);
        SpiceZigWait *token=spice_zig_wait_create(); assert(token);
        spice_zig_wait_cancel(session,token);
        SpiceZigSerialRequirement requirement={.type=2,.id=0,.serial=1};
        assert(spice_zig_session_wait(session,&requirement,1,token)==-31);
        spice_zig_wait_destroy(token); spice_zig_session_cancel(session); spice_zig_session_destroy(session);
    }
    puts("network C ABI sanitizer lifecycle checks passed");
}
