#include "../Vendor/ZeNative/ish/asbestos/guest-arm64/aot.h"
#include <stdbool.h>
#include <stddef.h>
bool ish_jit_is_enabled(void);
size_t jit_describe(char *buf, size_t size);
void fixture_module(const char *path, const char *build_id, const char *family);
void fixture_report(const char *report);
