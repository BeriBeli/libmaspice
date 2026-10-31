/* Independent fixed marker fixture compressed by shipped libjpeg-turbo. */
#include <turbojpeg.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc,char **argv) {
 assert(argc==2);enum{WIDTH=400,HEIGHT=48};uint8_t pixels[WIDTH*HEIGHT*4];memset(pixels,127,sizeof(pixels));
 for(unsigned i=3;i<sizeof(pixels);i+=4)pixels[i]=255;
 const uint64_t values[]={0xa5c3,UINT64_C(0x0123456789abcdef),9,0xaabbccdd};const unsigned sizes[]={16,64,64,32};unsigned bit=0;
 for(unsigned part=0;part<4;part++)for(unsigned shift=sizes[part];shift>0;shift--,bit++) {
  uint8_t component=(values[part]&(UINT64_C(1)<<(shift-1)))?0:255;
  for(unsigned y=8+(bit/88)*4;y<12+(bit/88)*4;y++)for(unsigned x=8+(bit%88)*4;x<12+(bit%88)*4;x++) {
   uint8_t *p=pixels+(y*WIDTH+x)*4;p[0]=p[1]=p[2]=component;
  }
 }
 tjhandle handle=tj3Init(TJINIT_COMPRESS);assert(handle);assert(!tj3Set(handle,TJPARAM_QUALITY,100));assert(!tj3Set(handle,TJPARAM_SUBSAMP,TJSAMP_444));
 unsigned char *jpeg=NULL;size_t size=0;assert(!tj3Compress8(handle,pixels,WIDTH,WIDTH*4,HEIGHT,TJPF_BGRA,&jpeg,&size));
 FILE *file=fopen(argv[1],"wb");assert(file);assert(fwrite(jpeg,1,size,file)==size);assert(!fclose(file));tj3Free(jpeg);tj3Destroy(handle);return 0;
}
