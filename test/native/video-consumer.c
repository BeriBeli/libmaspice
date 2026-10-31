#include "video_bridge.h"
#include "graphics_bridge.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct {uint8_t *bytes;unsigned *released;} Owner;
static void release(void *pointer){Owner *o=pointer;(*o->released)++;free(o->bytes);free(o);}
static uint32_t u32(const uint8_t **cursor,const uint8_t *end){assert((size_t)(end-*cursor)>=4);const uint8_t *p=*cursor;*cursor+=4;return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static Owner *owner(const uint8_t *bytes,size_t size,unsigned *count){Owner *o=malloc(sizeof(*o));assert(o);o->bytes=malloc(size?size:1);assert(o->bytes);memcpy(o->bytes,bytes,size);o->released=count;return o;}
int main(int argc,char **argv){
    assert(argc==5);
    void *graphics=spice_zig_graphics_create(argv[1]);assert(graphics);
    unsigned completed=0;
    for(int file=2;file<argc;file++){
        FILE *input=fopen(argv[file],"rb");assert(input);assert(!fseek(input,0,SEEK_END));long length=ftell(input);assert(length>0 && length<1024*1024);rewind(input);
        uint8_t *bytes=malloc((size_t)length);assert(bytes);assert(fread(bytes,1,(size_t)length,input)==(size_t)length);fclose(input);
        const uint8_t *p=bytes,*end=bytes+length;uint32_t hevc=u32(&p,end),count=u32(&p,end);assert(count>=2 && count<=3);
        const uint8_t *sets[3];size_t sizes[3];
        for(unsigned i=0;i<count;i++){sizes[i]=u32(&p,end);assert(sizes[i]<=(size_t)(end-p));sets[i]=p;p+=sizes[i];}
        size_t size=u32(&p,end);assert(size==(size_t)(end-p));
        for(unsigned trial=0;trial<12;trial++){
            void *format=NULL,*session=NULL,*pixel=NULL;
            assert(spice_zig_video_format((int)hevc,sets,sizes,count,&format)==0 && format);
            assert(spice_zig_video_session(format,&session)==0 && session);assert(!spice_zig_video_realtime(session));
            int hw=0;assert(!spice_zig_video_hardware(session,&hw) && hw==1);
            unsigned released=0;size_t n=trial<4?size:(trial-4)*size/8;Owner *o=owner(p,n,&released);
            int32_t status=spice_zig_video_decode(session,format,o->bytes,n,trial,o,release,&pixel);
            if(trial<4)assert(status==0 && pixel);
            spice_zig_video_session_release(session);spice_zig_video_format_release(format);
            assert(released==1);
            if(pixel){uint32_t m[5];assert(!spice_zig_video_metadata(pixel,m));assert(m[0]==128 && m[1]==128);spice_zig_video_frame_retain(pixel);spice_zig_video_frame_release(pixel);assert(!spice_zig_video_lock(pixel));const uint8_t *base=NULL;size_t w,h,stride;assert(!spice_zig_video_plane(pixel,0,&base,&w,&h,&stride) && base && stride>=w);assert(!spice_zig_video_unlock(pixel));
                if(m[2]==2 && (m[3]==601 || m[3]==709)){
                    void *destination=spice_zig_graphics_frame_create(graphics,128,128);assert(destination);
                    uint32_t uniforms[32]={128,128,0,0,0,0,128,128,0,0,128,128,0,0,128,128};
                    float ranges[4]={m[4]==2?16.0f/255.0f:0.0f,m[4]==2?255.0f/219.0f:1.0f,128.0f/255.0f,m[4]==2?255.0f/224.0f:1.0f};
                    float colors[12]={1,0,m[3]==709?1.5748f:1.402f,0,1,m[3]==709?-.187324f:-.344136f,m[3]==709?-.468124f:-.714136f,0,1,m[3]==709?1.8556f:1.772f,0,0};
                    memcpy(uniforms+16,ranges,sizeof(ranges));memcpy(uniforms+20,colors,sizeof(colors));
                    assert(!spice_zig_graphics_compose_video(graphics,pixel,destination,uniforms));spice_zig_graphics_frame_destroy(destination);
                }
                spice_zig_video_frame_release(pixel);
            }
            completed++;
        }
        free(bytes);
    }
    spice_zig_graphics_destroy(graphics);
    printf("%u native valid/truncated AVCC ownership cases passed with ASan/UBSan\n",completed);return 0;
}
