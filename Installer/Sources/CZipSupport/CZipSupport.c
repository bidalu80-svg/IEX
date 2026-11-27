#include "CZipSupport.h"
#include <limits.h>
#include <zlib.h>

int ze_inflate(const uint8_t *input, size_t input_count, uint8_t *output, size_t output_count) {
    if (input_count > UINT_MAX || output_count > UINT_MAX) return 0;
    z_stream stream = {0};
    // Even an empty DEFLATE stream needs output space to consume its end marker.
    unsigned char empty;
    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)input_count;
    stream.next_out = output_count ? output : &empty;
    stream.avail_out = output_count ? (uInt)output_count : 1;
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return 0;
    int status = inflate(&stream, Z_FINISH);
    int valid = status == Z_STREAM_END && stream.total_in == input_count && stream.total_out == output_count;
    inflateEnd(&stream);
    return valid;
}
uint32_t ze_crc32(const uint8_t *bytes, size_t count) {
    uLong crc = crc32(0L, Z_NULL, 0);
    while (count) {
        uInt chunk = count > UINT_MAX ? UINT_MAX : (uInt)count;
        crc = crc32(crc, bytes, chunk);
        bytes += chunk;
        count -= chunk;
    }
    return (uint32_t)crc;
}
