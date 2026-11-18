/* Native boundary fixture only; Swift production parsing/formatting is compiled unchanged. */
#include "AOJITHarness.h"
#include <stdio.h>
#include <string.h>
static struct aot_module image;
static char path[1024], family[256], report[65536];
void fixture_module(const char *p, const char *id, const char *f) {
    memset(&image, 0, sizeof(image));
    snprintf(path, sizeof(path), "%s", p);
    snprintf(family, sizeof(family), "%s", f);
    image.path = path; image.family = family;
    for (unsigned i = 0; i < 20 && strlen(id) >= (i + 1) * 2; i++) {
        unsigned byte;
        if (sscanf(id + i * 2, "%2x", &byte) != 1) break;
        image.build_id[image.build_id_len++] = byte;
    }
}
unsigned ish_aot_image_count(void) { return path[0] ? 1 : 0; }
const struct aot_module *ish_aot_image_metadata(unsigned i) { return i == 0 && path[0] ? &image : NULL; }
bool ish_jit_is_enabled(void) { return true; }
void fixture_report(const char *r) { snprintf(report, sizeof(report), "%s", r); }
size_t jit_describe(char *buf, size_t size) {
    size_t n = strlen(report);
    if (size) snprintf(buf, size, "%s", report);
    return n < size ? n : size;
}
