#include "graphics_bridge.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>
void *spice_zig_jpeg_create(void);
void spice_zig_jpeg_destroy(void *);
int spice_zig_jpeg_header(void *,const uint8_t *,size_t,int *,int *,int *);
int spice_zig_quic_image(const uint8_t *,size_t,int,int,uint8_t *,size_t,int *);
struct Completion {pthread_mutex_t mutex;pthread_cond_t changed;int done;};
static void completed(void *user,int status){
    struct Completion *state=user;assert(status==0);pthread_mutex_lock(&state->mutex);state->done=1;pthread_cond_signal(&state->changed);pthread_mutex_unlock(&state->mutex);
}
int main(int argc,char **argv) {
    assert(argc==3);
    for(unsigned n=0;n<16;n++) {
        void *g=spice_zig_graphics_create(argv[1]);assert(g);
        void *a=spice_zig_graphics_frame_create(g,5,3),*b=spice_zig_graphics_frame_create(g,5,3),*c=spice_zig_graphics_frame_create(g,8,7);assert(a&&b&&c);
        uint8_t *p=NULL;size_t stride=0,size=0;assert(!spice_zig_graphics_frame_lock(a,1,&p,&stride,&size));memset(p,255,size);assert(!spice_zig_graphics_frame_unlock(a,1));
        assert(!spice_zig_graphics_copy(g,a,b));
        uint32_t rects[12]={0,0,5,3,0,0,8,7,0,0,8,7};assert(!spice_zig_graphics_compose_bgra(g,a,c,rects,0));assert(!spice_zig_graphics_lanczos(g,a,c));
        assert(spice_zig_graphics_copy(g,a,c));rects[0]=UINT32_MAX;assert(spice_zig_graphics_compose_bgra(g,a,c,rects,0));
        void *presenter=spice_zig_presenter_create(g,argv[2]);assert(presenter);
        struct Completion completion={PTHREAD_MUTEX_INITIALIZER,PTHREAD_COND_INITIALIZER,0};
        assert(!spice_zig_presenter_submit(presenter,a,spice_zig_graphics_frame_texture(c),NULL,8,7,1,completed,&completion));
        // Submitted command retains source/context/presenter after caller release.
        spice_zig_presenter_destroy(presenter);spice_zig_graphics_frame_destroy(a);a=NULL;
        spice_zig_graphics_destroy(g);
        pthread_mutex_lock(&completion.mutex);while(!completion.done)pthread_cond_wait(&completion.changed,&completion.mutex);pthread_mutex_unlock(&completion.mutex);
        pthread_cond_destroy(&completion.changed);pthread_mutex_destroy(&completion.mutex);
        assert(!spice_zig_graphics_frame_lock(c,0,&p,&stride,&size));
        for(unsigned y=0;y<7;y++)for(unsigned x=0;x<32;x++)assert(p[y*stride+x]==255);
        assert(!spice_zig_graphics_frame_unlock(c,0));
        spice_zig_graphics_frame_destroy(a);spice_zig_graphics_frame_destroy(b);spice_zig_graphics_frame_destroy(c);
        void *jpeg=spice_zig_jpeg_create();assert(jpeg);
        uint8_t malformed[32]={0},output[64];int w=0,h=0,cmyk=0,type=0;
        memset(output,0xa5,sizeof output);
        for(size_t end=0;end<sizeof malformed;end++)assert(spice_zig_jpeg_header(jpeg,malformed,end,&w,&h,&cmyk));
        assert(spice_zig_quic_image(malformed,sizeof malformed,1,1,output+16,4,&type));
        for(unsigned i=0;i<16;i++)assert(output[i]==0xa5&&output[20+i]==0xa5);
        spice_zig_jpeg_destroy(jpeg);
    }
    puts("native graphics and codec adapter ASan/UBSan lifecycles passed");
}
