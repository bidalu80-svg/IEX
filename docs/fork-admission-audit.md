# Fork admission policy audit

Reference application `OpenMinis/OpenMinis@1a71df0f381cefde80bf912b723de6f9831bc177`,
`src/ios/iSH/ISHKernel.m`; its pinned `OpenMinis/ish-arm64` dependency
`0fd17a135e78b7a0cf08a4f5831217bbb76ed22f`, `kernel/fork.c` and `kernel/task.h`.
Fetched-source SHA-256/Git blob hashes and local pre-edit hashes are in
`fork-admission-source-manifest.json`.

## Confirmed gap and applied behavior

Ze already had the atomic `ish_set_fork_guard` hook before `task_create_` in
`sys_clone`, but the host did not install a callback. Anonymous mmap admission
does not cover task/pid/pthread allocations during fork. The existing mmap
brake is retained; the reference fork policy is now installed before guest
process execution without changing AOJIT, the CPU governor or memory thresholds.

| Policy | Exact reference behavior now present |
| --- | --- |
| Footprint ceiling | Physical RAM / 4, clamped to 500 MiB through 2048 MiB; unknown RAM uses 500 MiB. |
| Common path | Unknown footprint or below ceiling allows immediately; normal system pressure also allows up to and including 1.5 times ceiling. |
| Pressure path | At/above ceiling under warning/critical, or strictly above 1.5 times ceiling regardless of pressure, poll every 50 ms, at most 2 seconds. |
| Recovery | Resume if footprint falls, becomes unknown, or pressure clears and footprint is no longer above 1.5 times ceiling. |
| Timeout | Log and allow. This is reference backpressure, not a new rejection policy; BusyBox xargs can drop work on a failed fork. |
| Footprint observation | Existing reference 250 ms atomic cache limits common-path task_info calls; pressure polling performs fresh readings. |
| Thermal fork rate | Nominal 400/s, fair 250/s, serious 120/s, critical 60/s, unknown state 250/s; burst is twice the selected rate. |
| Light callers | Per-task decayed recent-fork count below 12 bypasses an exhausted bucket. |
| Heavy callers | Reserve a future token; sleep outside the mutex, at most 500 ms. Sleep time is excluded from the caller's measured pace. |
| Thread exemption | CLONE_THREAD bypasses both fork policies, matching reference. |
| Failure feedback | Existing negative guest errno propagation and task_start cleanup are retained. The reference fork policy itself does not invent ENOMEM/EAGAIN failures. |

`MemoryPressureMonitor` previously subscribed only to warning/critical events.
After critical, no normal event could clear its `critical` flag. It now also
subscribes to `.normal`, and the existing assignment on its serial sampling
queue clears that flag before the next kernel status update. Existing 10% entry,
15% exit hysteresis and 2-second stale-feed failure remain unchanged.

## Threading and narrow adapters

- The guard callback is published with release/acquire atomics before task
  allocation. Ceiling is initialized before publishing; pressure/cache values
  are atomic. Waiting occurs on the calling guest thread, outside kernel locks.
- Rate tokens/timestamp are protected by the reference pthread mutex; settings
  and counters are atomic. The task's pace fields are used only by that task's
  guest thread. As in reference, fork copies these fields with the parent task.
- One reference race is corrected: the timestamp and configured rate are
  re-read **inside** the token-bucket mutex. Sampling before locking could let
  callers acquire in reverse timestamp order, underflow unsigned elapsed time,
  and spuriously refill the bucket. A concurrent disable is checked again under
  the lock before division by rate. No rate, threshold or wait limit changed.
- Thermal-observer installation uses dispatch_once. The host implementation
  omits reference-only Swift ResourceDiagnostics symbol calls because Ze has no
  such exported symbols; successful-fork and throttle counters remain in C.
- Cached footprint uses the reference relaxed atomics. The TTL is an advisory
  cache, not a hard global single-flight guarantee: simultaneous expiry can
  cause more than one reading; pressure-path readings are intentionally fresh.

## Verification and limits

```sh
# macOS, or Linux with a C11 compiler:
python3 scripts/test-fork-admission.py
# Actual local run:
CC=clang-16 python3 scripts/test-fork-admission.py
```

Local WSL Ubuntu / clang 16 execution exited 0. The test extracts production
functions rather than copying their policy and compiles a deterministic harness
with stubbed clocks, sleep and OS readings. Assertions cover RAM clamp boundaries,
unknown footprint, exact 1.5x threshold, normal recovery, bounded allow-on-timeout,
all thermal rates, burst depletion, heavy/light callers, 500 ms cap, disabled
governor, statistics, and unchanged mmap critical/normal hysteresis and stale-feed
failure. Source checks verify normal-event subscription, pre-allocation wiring,
thread exemption, two-times burst and locked clock/rate refresh.

This proves policy branches and deterministic recovery, not an iOS pressure
notification delivery or real fork-storm stress run. Full Xcode/libish compilation
and device thermal/memory stress remain separate gates. `git diff --check` passed
for the changed policy files. No workflow or build configuration was changed.

Rollback only the added guard/thermal sections and installation in ISHKernel.m,
the rate bucket/sys_clone call/counter in fork.c, pace fields/declarations in
task.h, and the normal-event subscription/comment. Preserve concurrent task_start
cleanup and all existing AOJIT, mmap and native ownership repairs.
