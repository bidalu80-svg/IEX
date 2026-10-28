#ifndef ASBESTOS_ARM64_AOT_H
#define ASBESTOS_ARM64_AOT_H

// AOT images: translations recorded from the PIC JIT (ISH_JIT_RECORD) and
// laid out as assembly by tools/jit_aot/gen.py. An image is not part of ish:
// a target that wants one adds the .S to its own sources, and a constructor
// in it calls ish_aot_register() at load time. The layout here must match
// what gen.py emits.

#include <stdint.h>

// Pointers from the tables are 32-bit offsets from the field itself (0: none),
// so the linker fixes them once and the loader has nothing to rebase.
static inline const void *aot_rel(const int32_t *field) {
    return *field ? (const char *) field + *field : (const void *) 0;
}

struct aot_seg {
    int32_t code;                 // -> the native code (aot_rel)
    uint32_t pos;                 // code-stream slot it replaces
    uint32_t words;
};

struct aot_loop {                 // self-loop block: promoted registers in [lo, hi)
    const uint32_t *lo, *hi;
    uint8_t n, pad[7];
    int8_t g[8], d[8], h[8];      // promoted guest reg, donor guest reg, host reg
};

// The key as stored: reg_key()'s 7 header words, then per unit 6 of its 9
// (start, end, n/follow/last, dpc, w0, w1): the high dpc word and the gadget
// words are always 0 in an image and left out (AOT_KEY_UNIT).
#define AOT_KEY_UNIT 6
struct aot_trans {
    uint64_t off;                 // file offset of the block
    uint32_t idx, nkey;           // module-context index; key length in words as reg_key() builds it
    int32_t key;                  // -> compact key (above)
    int32_t gadget;               // -> per unit an int32 (aot_rel) to the gadget at the unit's start, or 0
    int32_t seg;                  // -> struct aot_seg[nseg]
    uint32_t nseg, nunits;
    int32_t link[2];              // -> direct-link branch per jump_ip slot, or 0
    int32_t loop;                 // -> struct aot_loop, or 0
};

// Content hash of a translation's key (key_content_hash()) -> its index in
// trans[], sorted by hash: finds a block whose bytes moved in another version.
struct aot_hash {
    uint64_t hash;
    uint32_t trans, pad;
};

struct aot_module {
    const char *path;             // guest path of the module
    uint64_t size;
    uint8_t sha256[32];
    uint32_t ntrans, nidx;        // translations (sorted by off), context indices used
    const struct aot_trans *trans;
    int32_t prologue_words, entry_off, n_pinned;   // conventions the code was made with
    uint32_t abi;                 // jit_abi() of the ish that made it (layouts, code version)
    const uint32_t *text_start, *text_end;
    uint32_t build_id_len;        // NT_GNU_BUILD_ID of the module, matched before the path
    uint8_t build_id[20];
    const char *family;           // fnmatch() pattern over file names this image may also serve
                                  // (other versions: blocks are matched by content), or NULL
    const struct aot_hash *by_hash;
    uint32_t nhash, pad2;
};

// Called by an image's constructor, before main. Needs ish built with -Djit=true.
void ish_aot_register(const struct aot_module *m);

// [T-aojit-status] What this build actually has linked in. Without -Djit all
// three return 0/NULL: the host shows "not recorded" rather than guessing.
unsigned ish_aot_image_count(void);
const char *ish_aot_image_path(unsigned i);
unsigned long long ish_aot_image_size(unsigned i);

// [T-aojit-stats] Images that actually attached to a module (a linked image
// whose conventions do not match is skipped), blocks installed from an image,
// and blocks the JIT translated instead.
unsigned ish_aot_attached_count(void);
unsigned long long ish_aot_hits(void);
unsigned long long ish_aot_translated_blocks(void);
// [T-aojit-per-image] Per-attached-image diagnostics: same order as
// ish_aot_attached_path(), so a zero-hit image can be spotted by name.
const char *ish_aot_attached_path(unsigned i);
unsigned long long ish_aot_attached_size(unsigned i);
unsigned long long ish_aot_hits_for_image(unsigned i);

// [T-aojit-v2] Images the running JIT refused at registration (abi or pinned
// conventions differ) — the case that used to look like a working image.
unsigned ish_aot_rejected_count(void);
const char *ish_aot_rejected_path(unsigned i);
unsigned ish_aot_rejected_abi(unsigned i);
// [T-aojit-v2] How image i serves its module: 0 not attached, 1 same build
// (build-id or path matched), 2 family (another version of the same file,
// matched block by block through by_hash).
int ish_aot_image_match(unsigned i);
// [T-aojit-v2] Blocks installed from a family image (a different version of
// the module): the number that says version drift is being absorbed.
unsigned long long ish_aot_moved_hits(void);
// [T-aojit-v2] The abi this binary's JIT was built with, so the host can say
// why an image was rejected instead of just "not used".
unsigned ish_aot_jit_abi(void);

#endif
