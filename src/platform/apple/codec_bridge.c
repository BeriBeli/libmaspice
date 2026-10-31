// Narrow bindings to the existing native dependencies. Decode policy, bounds,
// CMYK conversion and publication stay in Zig.
#include "../../../pkg/quic/shim.h"
#include <turbojpeg.h>
void *spice_zig_jpeg_create(void) { return tjInitDecompress(); }
void spice_zig_jpeg_destroy(void *handle) { if(handle) tjDestroy(handle); }
int spice_zig_jpeg_header(void *handle,const uint8_t *data,size_t size,int *width,int *height,int *cmyk) {
    int subsampling=0,colorspace=0;
    if(!handle || !data || !width || !height || !cmyk || size>ULONG_MAX)return -1;
    int status=tjDecompressHeader3(handle,data,(unsigned long)size,width,height,&subsampling,&colorspace);
    *cmyk=colorspace==TJCS_CMYK || colorspace==TJCS_YCCK;return status;
}
int spice_zig_jpeg_pixels(void *handle,const uint8_t *data,size_t size,uint8_t *output,int width,int stride,int height,int cmyk) {
    if(!handle || !data || !output || size>ULONG_MAX)return -1;
    return tjDecompress2(handle,data,(unsigned long)size,output,width,stride,height,cmyk?TJPF_CMYK:TJPF_BGRA,TJFLAG_STOPONWARNING);
}
int spice_zig_quic_image(const uint8_t *data,size_t size,int width,int height,uint8_t *output,size_t output_size,int *type) {
    int decoded_width=0,decoded_height=0;
    return spice_swift_quic_decode(data,size,width,height,output,output_size,type,&decoded_width,&decoded_height);
}
