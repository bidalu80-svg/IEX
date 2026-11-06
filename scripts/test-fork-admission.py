#!/usr/bin/env python3
"""Execute production fork/rate/brake policy with deterministic clocks/OS readings."""
from pathlib import Path
import os, re, shutil, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[1]
host = (ROOT / 'iSH/ISHKernel.m').read_text(encoding='utf-8')
fork = (ROOT / 'Vendor/ZeNative/ish/kernel/fork.c').read_text(encoding='utf-8')
mmap = (ROOT / 'Vendor/ZeNative/ish/kernel/mmap.c').read_text(encoding='utf-8')
monitor = (ROOT / 'Agent/ISH/MemoryPressureMonitor.swift').read_text(encoding='utf-8')

def fn(s, marker):
    a = s.index(marker); b = s.index('{', a); depth = 1; i = b + 1
    while depth:
        depth += (s[i] == '{') - (s[i] == '}'); i += 1
    return s[a:i]

defines = '\n'.join(x for x in host.splitlines() if x.startswith('#define ZE_FORK_GUARD_'))
ceiling = fn(host, 'static uint64_t ze_fork_guard_compute_ceiling(').replace('[NSProcessInfo processInfo].physicalMemory', 'fixture_ram')
guard = fn(host, 'static int ze_fork_memory_guard(')
# ObjC logging is the only syntax adapter; the actual policy body is unmodified.
guard = re.sub(r'NSLog\(@.*?;', '(void)first_footprint;', guard, flags=re.S)
thermal = fn(host, 'static unsigned ze_fork_rate_for_thermal(')
rate = fork[fork.index('// [T-ish-cpu-top]'):fork.index('#define CSIGNAL_')]
brake = mmap[mmap.index('static _Atomic int ish_mem_state_v'):mmap.index('bool anon_pages_reserve(')]
header = r'''
#define _DEFAULT_SOURCE
#include <assert.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
#define NSEC_PER_MSEC 1000000ull
#define BOOL bool
#define printk(...) ((void)0)
typedef int NSProcessInfoThermalState;
enum { NSProcessInfoThermalStateNominal, NSProcessInfoThermalStateFair,
       NSProcessInfoThermalStateSerious, NSProcessInfoThermalStateCritical };
enum { ISH_MEM_OK, ISH_MEM_BRAKE };
struct task { uint64_t fork_rate_last_ns; double fork_rate_ewma; };
static uint64_t fixture_ram, fixture_now=1000000000ull, fixture_footprint;
static uint64_t slept_ns, polled_us;
static bool clear_pressure_on_poll;
static atomic_ullong g_fork_guard_stalls;
static atomic_uint_fast32_t g_fork_guard_pressure;
static uint64_t g_fork_guard_max_footprint;
static _Atomic uint64_t g_fork_guard_footprint_cached, g_fork_guard_footprint_stamp;
static uint64_t mach_absolute_time(void) { return fixture_now; }
static uint64_t ze_current_phys_footprint(void) { return fixture_footprint; }
static uint64_t ze_read_phys_footprint(void) { return fixture_footprint; }
static int fixture_usleep(useconds_t us) {
    polled_us += us; fixture_now += (uint64_t)us*1000;
    if(clear_pressure_on_poll) atomic_store(&g_fork_guard_pressure,0);
    return 0;
}
static int fixture_clock(clockid_t id, struct timespec *ts) {
    (void)id; ts->tv_sec=fixture_now/1000000000ull; ts->tv_nsec=fixture_now%1000000000ull; return 0;
}
static int fixture_sleep(const struct timespec *ts, struct timespec *rem) {
    (void)rem; uint64_t n=ts->tv_sec*1000000000ull+ts->tv_nsec;
    slept_ns+=n; fixture_now+=n; return 0;
}
#define usleep fixture_usleep
#define clock_gettime fixture_clock
#define nanosleep fixture_sleep
'''
checks = r'''
int main(void) {
    const uint64_t mb=1024ull*1024;
    fixture_ram=0; assert(ze_fork_guard_compute_ceiling()==500*mb);
    fixture_ram=1024*mb; assert(ze_fork_guard_compute_ceiling()==500*mb);
    fixture_ram=4096*mb; assert(ze_fork_guard_compute_ceiling()==1024*mb);
    fixture_ram=8192*mb; assert(ze_fork_guard_compute_ceiling()==2048*mb);
    fixture_ram=12288*mb; assert(ze_fork_guard_compute_ceiling()==2048*mb);
    g_fork_guard_max_footprint=1000*mb;
    fixture_footprint=0; assert(ze_fork_memory_guard()==0 && polled_us==0);
    fixture_footprint=999*mb; atomic_store(&g_fork_guard_pressure,2);
    assert(ze_fork_memory_guard()==0 && polled_us==0);
    atomic_store(&g_fork_guard_pressure,0); fixture_footprint=1500*mb;
    assert(ze_fork_memory_guard()==0 && polled_us==0);
    fixture_footprint++; assert(ze_fork_memory_guard()==0 && polled_us==2000000);
    polled_us=0; fixture_footprint=1000*mb; atomic_store(&g_fork_guard_pressure,1);
    clear_pressure_on_poll=true;
    assert(ze_fork_memory_guard()==0 && polled_us==50000);
    clear_pressure_on_poll=false; polled_us=0; atomic_store(&g_fork_guard_pressure,2);
    assert(ze_fork_memory_guard()==0 && polled_us==2000000);
    puts("PASS: real footprint policy clamp, unknown, normal boundary, 1.5x, pressure recovery, bounded allow-on-timeout");

    assert(ze_fork_rate_for_thermal(0)==400 && ze_fork_rate_for_thermal(1)==250);
    assert(ze_fork_rate_for_thermal(2)==120 && ze_fork_rate_for_thermal(3)==60);
    assert(ze_fork_rate_for_thermal(99)==250);
    ish_set_fork_rate_limit(100,2);
    struct task heavy={.fork_rate_last_ns=fixture_now,.fork_rate_ewma=20};
    fork_rate_wait(&heavy); fork_rate_wait(&heavy); assert(slept_ns==0);
    fork_rate_wait(&heavy); assert(slept_ns==10000000);
    uint64_t before=slept_ns;
    struct task light={0}; fork_rate_tokens=-100; fork_rate_last_ns=fixture_now;
    fork_rate_wait(&light); assert(slept_ns==before);
    heavy.fork_rate_last_ns=fixture_now;heavy.fork_rate_ewma=20;
    fork_rate_wait(&heavy);assert(slept_ns-before==500000000);
    assert(heavy.fork_rate_last_ns==fixture_now);
    ish_set_fork_rate_limit(0,0);before=slept_ns;fork_rate_wait(&heavy);assert(slept_ns==before);
    ish_set_fork_rate_limit(60,0);assert(fork_rate_tokens==60);
    uint64_t throttled,bypassed,slept;ish_fork_rate_stats(&throttled,&bypassed,&slept);
    assert(throttled==2 && bypassed==1 && slept==510000000);
    puts("PASS: real thermal map, burst, heavy wait, light bypass, 500ms cap, disable, statistics");

    assert(!ish_footprint_mode() && ish_mem_commit_ok(1));
    ish_set_memory_status(1000,200,true); assert(!ish_mem_commit_ok(0));
    ish_set_memory_status(1000,149,false);assert(!ish_mem_commit_ok(0));
    ish_set_memory_status(1000,150,false);assert(ish_mem_commit_ok(0));
    ish_set_memory_status(1000,99,false);assert(!ish_mem_commit_ok(0));
    ish_set_memory_status(1000,200,false);assert(ish_mem_commit_ok(0));
    assert(!ish_mem_commit_ok(1001)); fixture_now+=2001000000ull;
    assert(!ish_mem_commit_ok(0));
    puts("PASS: unchanged mmap policy critical -> normal recovery, 10/15 percent hysteresis, oversized/stale failure");
}
'''
code = header + defines + '\n' + ceiling + '\n' + guard + '\n' + thermal + '\n' + rate + '\n' + brake + checks
out = Path(os.environ.get('RUNNER_TEMP', tempfile.gettempdir())) / 'ze-fork-admission-tests'
out.mkdir(exist_ok=True)
source = out / 'fork-admission.c'; source.write_text(code, encoding='utf-8')
compiler = ['xcrun', 'clang'] if shutil.which('xcrun') else [os.environ.get('CC', 'cc')]
subprocess.run(compiler + ['-std=c11', '-Wall', '-Wextra', '-pthread', str(source), '-o', str(out/'checks')], check=True)
subprocess.run([str(out/'checks')], check=True, timeout=15)
assert 'eventMask: [.normal, .warning, .critical]' in monitor
assert 'self.critical = source.data.contains(.critical)' in monitor
clone = fn(fork, 'dword_t sys_clone(')
assert clone.index('fork_rate_wait(current)') < clone.index('task_create_(current)')
assert 'if (!(flags & CLONE_THREAD_))' in clone
assert 'ish_set_fork_guard(ze_fork_memory_guard)' in host
assert 'ish_set_fork_rate_limit(rate, rate * 2)' in host
wait = fn(fork, 'static void fork_rate_wait(')
locked = wait[wait.index('pthread_mutex_lock(&fork_rate_lock)'):]
assert locked.index('now = fork_rate_now_ns()') < locked.index('now - fork_rate_last_ns')
assert locked.index('rate = atomic_load') < locked.index('if (rate == 0)')
print('PASS: real normal-event subscription, caller-before-allocation wiring, thermal burst and locked timestamp')
