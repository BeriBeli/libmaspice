#import <Foundation/Foundation.h>
#include "webdav_bridge.h"
#include <stdlib.h>
#include <string.h>
int spice_zig_webdav_string(uint32_t operation,const uint8_t *bytes,size_t length,uint8_t **output,size_t *output_length){
 if(!output||!output_length||(!bytes&&length)||length>INT64_MAX)return -1;
 *output=NULL;*output_length=0;
 @autoreleasepool {
  NSString *input=[[NSString alloc] initWithBytes:(bytes ? bytes : (const uint8_t *)"") length:length encoding:NSUTF8StringEncoding];
  if(!input)return -1;
  if(length>=3&&bytes[0]==0xef&&bytes[1]==0xbb&&bytes[2]==0xbf)input=[@"\uFEFF" stringByAppendingString:input];
  NSString *result=nil;
  switch(operation){
   case 0:{NSURLComponents *url=[NSURLComponents componentsWithString:input];if(!url)return 1;result=url.percentEncodedPath.stringByRemovingPercentEncoding;break;}
   case 1:result=input.stringByRemovingPercentEncoding;break;
   case 2:result=[NSURL fileURLWithPath:input].URLByStandardizingPath.URLByResolvingSymlinksInPath.path;break;
   case 3:result=[input stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];break;
   default:return -1;
  }
  if(!result)return -1;
  NSData *data=[result dataUsingEncoding:NSUTF8StringEncoding];if(!data)return -1;
  uint8_t *copy=malloc(MAX((size_t)1,data.length));if(!copy)return -2;
  if(data.length)memcpy(copy,data.bytes,data.length);*output=copy;*output_length=data.length;return 0;
 }
}

int spice_zig_webdav_date(double seconds,uint8_t **output,size_t *output_length){
 if(!output||!output_length)return -1;*output=NULL;*output_length=0;
 @autoreleasepool {
  NSDateFormatter *format=[NSDateFormatter new];format.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];format.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0];format.dateFormat=@"EEE, dd MMM yyyy HH:mm:ss 'GMT'";
  NSData *data=[[format stringFromDate:[NSDate dateWithTimeIntervalSince1970:seconds]] dataUsingEncoding:NSUTF8StringEncoding];if(!data)return -1;
  uint8_t *copy=malloc(MAX((size_t)1,data.length));if(!copy)return -2;if(data.length)memcpy(copy,data.bytes,data.length);*output=copy;*output_length=data.length;return 0;
 }
}

#include <fcntl.h>
int spice_zig_webdav_open_directory(int parent,const char *path){return openat(parent,path,O_SEARCH|O_CLOEXEC|O_NOFOLLOW);}
