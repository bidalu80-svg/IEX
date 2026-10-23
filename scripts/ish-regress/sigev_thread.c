// [T-ish-sigev-thread] Regression tests for the two defects behind the
// SIGEV_THREAD / signal-32 crash.
//
// Build and run inside the guest (musl):
//     cc /var/ze/workspace/scripts/ish-regress/sigev_thread.c \\
//        -o /tmp/sigev_thread -pthread && /tmp/sigev_thread
//
// Each case prints PASS or FAIL; the process exits non-zero if any failed, so
// it can be driven from a shell loop as well as read by hand.

#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

// musl's timer_create(SIGEV_THREAD) is an internal thread waiting on SIGTIMER.
#ifndef SIGTIMER
#define SIGTIMER 32
#endif

static int failures;

static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok)
        failures++;
}

static long long now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long) ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

// ---------------------------------------------------------------- case 1
// SIGEV_THREAD_ID must deliver to the tid the caller named, not the leader.
//
// Nothing installs a handler: SIGUSR1 stays blocked everywhere, so the signal
// is only ever visible through a queue. If it lands on the wrong thread the
// waiting worker times out, and — because the leader never consumes it — the
// signal is still pending for the leader afterwards.

static sigset_t tid_set;
static volatile int tid_worker_got;
static volatile int tid_worker_ready;
static volatile pid_t tid_worker_tid;

static void *tid_worker(void *arg) {
    (void) arg;
    tid_worker_tid = (pid_t) syscall(SYS_gettid);
    __atomic_store_n(&tid_worker_ready, 1, __ATOMIC_RELEASE);

    struct timespec timeout = {.tv_sec = 0, .tv_nsec = 400 * 1000 * 1000};
    int sig = sigtimedwait(&tid_set, NULL, &timeout);
    if (sig == SIGUSR1)
        __atomic_store_n(&tid_worker_got, 1, __ATOMIC_RELEASE);
    return NULL;
}

static void test_thread_id_delivery(void) {
    sigemptyset(&tid_set);
    sigaddset(&tid_set, SIGUSR1);
    sigprocmask(SIG_BLOCK, &tid_set, NULL);   // inherited by the worker

    pthread_t worker;
    if (pthread_create(&worker, NULL, tid_worker, NULL) != 0) {
        check(0, "SIGEV_THREAD_ID: worker thread created");
        return;
    }
    while (!__atomic_load_n(&tid_worker_ready, __ATOMIC_ACQUIRE))
        usleep(1000);

    pid_t target = __atomic_load_n(&tid_worker_tid, __ATOMIC_ACQUIRE);
    if (target <= 0 || target == getpid()) {
        check(0, "SIGEV_THREAD_ID: worker tid differs from the leader");
        pthread_join(worker, NULL);
        return;
    }

    timer_t timer;
    struct sigevent sev;
    memset(&sev, 0, sizeof sev);
    sev.sigev_notify = SIGEV_THREAD_ID;
    sev.sigev_signo = SIGUSR1;
    sev.sigev_notify_thread_id = target;
    int rc = timer_create(CLOCK_MONOTONIC, &sev, &timer);
    check(rc == 0, "SIGEV_THREAD_ID: timer_create accepted the tid");

    if (rc == 0) {
        struct itimerspec its;
        memset(&its, 0, sizeof its);
        its.it_value.tv_nsec = 20 * 1000 * 1000;
        timer_settime(timer, 0, &its, NULL);
    }

    pthread_join(worker, NULL);
    if (rc == 0)
        timer_delete(timer);

    check(__atomic_load_n(&tid_worker_got, __ATOMIC_ACQUIRE) == 1,
          "SIGEV_THREAD_ID: signal reached the requested thread");

    sigset_t pending;
    sigemptyset(&pending);
    sigpending(&pending);
    check(!sigismember(&pending, SIGUSR1),
          "SIGEV_THREAD_ID: group leader did not keep the signal");
}

// ---------------------------------------------------------------- case 2
// sigtimedwait must return a signal that is pending but blocked.

static void test_sigtimedwait(int signo, const char *label) {
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, signo);
    sigset_t old;
    sigprocmask(SIG_BLOCK, &set, &old);

    // Blocked, so this only queues it — which is exactly the state sigwait
    // is specified to collect.
    raise(signo);

    struct timespec timeout = {.tv_sec = 1, .tv_nsec = 0};
    siginfo_t info;
    memset(&info, 0, sizeof info);
    errno = 0;
    int got = sigtimedwait(&set, &info, &timeout);

    char what[160];
    snprintf(what, sizeof what, "sigtimedwait(%d, %s) returned the signal", signo, label);
    check(got == signo, what);

    snprintf(what, sizeof what, "sigtimedwait(%d, %s) filled si_signo", signo, label);
    check(info.si_signo == signo, what);

    sigprocmask(SIG_SETMASK, &old, NULL);
}

// ---------------------------------------------------------------- case 3
// An expired sigtimedwait returns EAGAIN, and consumes the timeout once.

static void test_sigtimedwait_timeout(void) {
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGUSR2);

    struct timespec timeout = {.tv_sec = 0, .tv_nsec = 120 * 1000 * 1000};
    long long t0 = now_ns();
    errno = 0;
    int rc = sigtimedwait(&set, NULL, &timeout);
    int e = errno;
    long long elapsed_ms = (now_ns() - t0) / 1000000;

    check(rc == -1 && e == EAGAIN, "sigtimedwait with nothing pending returns EAGAIN");
    check(elapsed_ms >= 100 && elapsed_ms < 600,
          "sigtimedwait honoured the requested timeout once");
}

// ---------------------------------------------------------------- case 4
// The original crash: a SIGEV_THREAD timer must fire repeatedly, not kill us.

static volatile int thread_notifications;

static void thread_cb(union sigval sv) {
    (void) sv;
    __atomic_add_fetch(&thread_notifications, 1, __ATOMIC_RELAXED);
}

static void test_sigev_thread_timer(void) {
    struct sigevent sev;
    memset(&sev, 0, sizeof sev);
    sev.sigev_notify = SIGEV_THREAD;
    sev.sigev_notify_function = thread_cb;

    timer_t timer;
    int rc = timer_create(CLOCK_MONOTONIC, &sev, &timer);
    check(rc == 0, "SIGEV_THREAD: timer_create succeeded");
    if (rc != 0)
        return;

    struct itimerspec its;
    memset(&its, 0, sizeof its);
    its.it_value.tv_nsec = 20 * 1000 * 1000;
    its.it_interval.tv_nsec = 20 * 1000 * 1000;
    timer_settime(timer, 0, &its, NULL);

    struct timespec wait = {.tv_sec = 0, .tv_nsec = 300 * 1000 * 1000};
    nanosleep(&wait, NULL);
    timer_delete(timer);

    // Reaching this line at all means the process survived the expiry; the
    // counter proves the callback actually ran.
    check(__atomic_load_n(&thread_notifications, __ATOMIC_RELAXED) >= 3,
          "SIGEV_THREAD: callback fired repeatedly without killing the process");
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("musl SIGTIMER=%d\n", SIGTIMER);

    test_sigtimedwait(SIGUSR2, "SIGUSR2");
    test_sigtimedwait(SIGTIMER, "SIGTIMER");
#ifdef SIGRTMIN
    test_sigtimedwait(SIGRTMIN, "SIGRTMIN");
#endif
    test_sigtimedwait_timeout();
    test_thread_id_delivery();
    test_sigev_thread_timer();

    if (failures)
        printf("\n%d check(s) FAILED\n", failures);
    else
        printf("\nall checks passed\n");
    return failures ? 1 : 0;
}
