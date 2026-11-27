#ifndef ZE_ZIP_SUPPORT_H
#define ZE_ZIP_SUPPORT_H
#include <stddef.h>
#include <stdint.h>
// Raw ZIP DEFLATE, with an exact bounded output allocation supplied by the caller.
int ze_inflate(const uint8_t *input, size_t input_count, uint8_t *output, size_t output_count);
uint32_t ze_crc32(const uint8_t *bytes, size_t count);
#endif
