#ifndef KERNEL_MM_H
#define KERNEL_MM_H

#include <stdatomic.h>
#include <stdbool.h>
#include "kernel/memory.h"
#include "misc.h"

// Maximum anonymous GUEST pages across ALL processes.
// Prevents iOS app from being killed by jetsam.
// 0 = no limit. Non-zero = hard limit in guest pages (4KB each).
// Go runtime alone needs ~1.1GB for page summary reservations (PROT_NONE),
// which do not count here — the mmap path exempts PROT_NONE explicitly.
//
// [T-ish-anon-cap-page-units] Budget the host, count the guest. This counter is
// in 4KB guest pages, but jetsam kills over HOST bytes, and on arm64 iOS the
// host page is 16KB. Every committed guest page takes a whole host page, so one
// counted page costs 16KB of footprint, not 4KB. Converting a host-byte budget
// with the guest page size over-permits by exactly 4x.
//
// That is not theoretical: 1048576 pages read as "4GB" here was really 4GB of
// guest pages = 16GB of host footprint, far above the point where iOS kills the
// app. A runaway guest allocation reached jetsam before it ever reached the
// cap, so the guest never got the ENOMEM that would have failed one command and
// the user lost the whole app instead.
//
// 131072 guest pages x 16KB host pages = 2GB of host memory.
#define ANON_MMAP_LIMIT_PAGES 131072

#if ANON_MMAP_LIMIT_PAGES > 0
extern _Atomic long anon_page_count;
// [T-ish-anon-cap-dynamic] Effective limit, host-tunable at boot; defaults to
// the ceiling so a host that never calls the setter keeps the fixed cap.
extern _Atomic long anon_page_limit;

// Clamp to the ceiling; a non-positive value means "could not measure" and
// leaves the default in place.
void ish_set_anon_page_limit(long pages);
// Check-and-add. A refusal adds nothing, unlike a blind fetch_add followed by a
// separate comparison, which races and leaks count on the failure path.
bool anon_pages_reserve(long pages);
void anon_pages_unreserve(long pages);

// [T-ish-anon-count-negative] Charge/uncharge must stay symmetric or the
// counter drifts negative and the cap silently grants free headroom.
// The single source of truth for "does this mapping count": PROT_NONE
// reservations occupy address space but no physical memory, so they are
// neither charged when mapped nor decremented when unmapped. do_mmap/brk,
// pt_unmap and pt_copy_on_write all gate on this - keep them agreeing.
static inline bool anon_page_is_charged(unsigned flags) {
    return (flags & (P_READ | P_WRITE | P_EXEC)) != 0;
}
#endif

// uses mem.lock instead of having a lock of its own
struct mm {
    atomic_uint refcount;
    struct mem mem;

    addr_t vdso; // immutable
    addr_t start_brk; // immutable
    addr_t brk;

    // crap for procfs
    addr_t argv_start;
    addr_t argv_end;
    addr_t env_start;
    addr_t env_end;
    addr_t auxv_start;
    addr_t auxv_end;
    addr_t stack_start;
    struct fd *exefile;

    // Main executable load bias + entry point (ARM64 only — used to
    // precisely identify V8's self-abort BRK site in node at signal time).
    addr_t exe_bias;
    addr_t exe_entry;
};

// Create a new address space
struct mm *mm_new(void);
// Clone (COW) the address space
struct mm *mm_copy(struct mm *mm);
// Increment the refcount
void mm_retain(struct mm *mem);
// Decrement the refcount, destroy everything in the space if 0
void mm_release(struct mm *mem);

#endif
