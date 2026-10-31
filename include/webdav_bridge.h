#ifndef SPICE_ZIG_WEBDAV_BRIDGE_H
#define SPICE_ZIG_WEBDAV_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
/* Foundation URL/Unicode boundary only. Output uses malloc; release with free.
 * 0: absolute URL -> decoded path (1 means URL parse failed; use raw path branch)
 * 1: raw percent decode, 2: canonical filesystem URL path, 3: URL path escaping.
 * Zero success, -1 invalid UTF-8/URL, -2 allocation failure. */
int spice_zig_webdav_string(uint32_t operation,const uint8_t *bytes,size_t length,uint8_t **output,size_t *output_length);
int spice_zig_webdav_date(double seconds,uint8_t **output,size_t *output_length);
int spice_zig_webdav_open_directory(int parent,const char *path);
#endif
