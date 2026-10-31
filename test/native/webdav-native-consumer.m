#include "webdav_bridge.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
static void check(uint32_t op,const char *input,const char *expected){
 uint8_t *output=NULL;size_t length=0;assert(!spice_zig_webdav_string(op,(const uint8_t *)input,strlen(input),&output,&length));assert(length==strlen(expected));assert(!memcmp(output,expected,length));free(output);
}
int main(void){
 for(unsigned i=0;i<256;i++){
  check(0,"https://host/a%20b?q=1#x","/a b");check(1,"/%E4%B8%AD","/中");check(3,"/a b&é","/a%20b&%C3%A9");
  uint8_t *output=NULL;size_t length=0;const uint8_t invalid[]={0xff};assert(spice_zig_webdav_string(1,invalid,1,&output,&length)==-1&&!output);
  assert(!spice_zig_webdav_string(1,NULL,0,&output,&length)&&!length);free(output);
  assert(!spice_zig_webdav_date(0,&output,&length));assert(length==29&&!memcmp(output,"Thu, 01 Jan 1970 00:00:00 GMT",length));free(output);
 }
 return 0;
}
