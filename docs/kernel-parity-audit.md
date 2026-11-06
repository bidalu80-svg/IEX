# Kernel parity audit

Reference app: `OpenMinis/OpenMinis@1a71df0f381cefde80bf912b723de6f9831bc177`.
Its `.gitmodules` identifies `deps/ish` as `OpenMinis/ish-arm64`; the app tree pins commit `0fd17a135e78b7a0cf08a4f5831217bbb76ed22f`. This audit compares that exact dependency with `Vendor/ZeNative/ish`, rather than counting files or treating the upstream branch tip as the shipped dependency. Blob hashes and fetched wrapper hashes are in `kernel-parity-source-manifest.json`.

## Scope and result

This change repairs independently identified command cancellation, ownership, routing and path handling defects. It is **not a claim that every native kernel difference has been merged or that device runtime parity is complete**. No vendored translator/core replacement was made: Ze's existing AOJIT switch, memory pressure monitor, exit-progress safeguards and guest architecture are retained.

| Area | Source evidence | Finding and disposition |
| --- | --- | --- |
| Concurrent shell execution | `Agent/ISH/ISHExecutionCoordinator.swift`, `iSH/ISHShellExecutor.m` | Already spawns an independent `/bin/sh`, pipes and fs_context per command. No serialization added. |
| Stop responsiveness | `stopAllNonisolated`, `runCommand` | Previous main/caller thread synchronously scanned the process table under pids_lock. Now snapshots ownership and dispatches kills to a serial utility path; timeout result and 3-second stop abandonment run independently of that queue. A blocked kill no longer blocks the UI or timeout result. |
| Stop owner isolation | `InflightExec.ownerId`, `AIChatViewModel+ISHCommand.runRaw`, `AIChatViewModel+BackgroundTask.stopCurrentCommand` | Previously the chat stop called unfiltered global stop. Commands now carry the issuing chat; child Stop filters both workspace and owner. On-demand shell installation carries the same owner. Global emergency stop remains available explicitly. |
| Stuck native I/O | `registerAbandon`, `stopAbandonGrace` | Stop releases the awaiting tool result after 3 seconds if the guest never exits. This releases the wait; it does not assert that an uninterruptible native syscall has terminated. Native executor cleanup is queued separately. |
| Timeout output | `recordPartial`, `partialSnapshot` | Preserves newest output before timeout/abandon, marks truncation, bounds the mirror to 256,000 characters including an oversized individual line. |
| Continuation races | `claimResume`, late abandon registration cleanup | Existing NSLock one-shot continuation guard retained. Completion racing registration no longer leaves an already-finished abandon handle. |
| Cancel before execution | `execute` defer ordering | Removal is registered before `Task.checkCancellation`, avoiding a leaked PID-zero inflight record. This does not add arbitrary Task.cancel propagation into a running guest. |
| Filesystem routing | `Agent/ISH/ZeFsRouter.swift` | Existing forward/reverse routing and prefix boundary were functionally equivalent. Tokens now key `(workspace, owner)`: file access retains shared workspace, native browser/offload caller identity resolves the actual child. Reverse lookup uses a known-workspace set. Unknown nonzero tokens return nil; only zero legacy tokens may use mounted-session fallback. |
| Guest-thread native context | `NativeOffloads/NativeOffloadUtils.h/.m` | Adds `noff_current_fs_context` from thread-local current task before any MainActor hop; browser agent uses the coordinator caller API. |
| Native path idempotence | `noff_resolve_host_path` | Already-translated host argv paths are no longer nested under rootfs again. Sandbox/shared-container matches use a path-component boundary, including `/private/var` form. |
| Process sweep | `ISHTaskIsDescendantOf`, `killProcessGroup` | Parent chain validates task identity through pid table; root and swept tasks guard absent groups before dereference. Existing delayed root PID reuse check retained. This is upstream-equivalent hardening, not proof of complete task lifetime safety. |
| Offload command scope | `kernel/native_offload_policy.c/.h`, `kernel/exec.c` | Policy files have identical normalized Git blobs at the pinned commit; shebang bypass, explicit guest path scope and `NO_OFFLOAD` switches already exist. Existing real C tests are reused. |
| Procfs/exit memory lifetime | `kernel/exit.c`, `fs/proc/pid.c` | Ze already clears mm/mem under general_lock before release. `fs/proc/pid.c` blob is identical. Ze also has exit-progress/poll-floor changes absent in the pin; preserved. |
| AOJIT/AOT | `Agent/ISH/AOJITAcceleration.swift`, `asbestos/guest-arm64/jit.h/.c`, native preparation scripts | Ze runtime enable/disable declarations differ intentionally from the pin; no blanket replacement. Execute still starts MemoryPressureMonitor independently of AOJIT enabled state. Simulator native build remains distinct from device build. |

## Remaining inspected differences

These are explicit outstanding differences, not verified parity or automatically approved changes. Scope was frozen for integration after the targeted fixes above.

- Upstream `kernel/native_offload.c` adds in-process abort-handler registration and signal forwarding. Ze does not yet contain that interface. Three-second coordinator abandonment is a bounded UI/tool wait, not an implementation of that guest/native cancellation protocol.
- Upstream `fs/fake.c` has additional O_NOFOLLOW and path handling hardening; `fs/path.c`, `fs/real.c`, task/fork/signal and exec implementations differ. The native manifest inventories these exact file differences. They require their own focused regression and integration review; file-count equality would establish nothing.
- Upstream `ISHKernel.m` has additional crash diagnostics, fork footprint controls and background CPU governor changes. Ze already has background throttling/governor and separate memory monitoring, but this patch does not establish equivalent runtime budgets or jetsam behavior.
- Upstream RootfsManager adds failed-delete fallback that renames a broken rootfs tree before reinstalling. Ze's existing install/reset path remains unchanged here. Corrupt/deep-tree recovery is therefore an identified gap.
- No local Windows tool can establish Darwin guest execution, iOS background suspension behavior or AOJIT speed. Device-specific behavior remains pending even if the macOS fixture and app build pass.

## Reproducible verification

1. `python3 scripts/test-kernel-runtime.py`: extracts the real coordinator execute/runCommand/stop machinery and complete router into a macOS Swift harness. Native execution is a deterministic boundary fixture. Verifies owner tokens/shared paths, unknown token refusal, blocked kill queue timeout, newest bounded output, owner-only stop, 3-second abandonment, sibling completion, synchronous completion and pre-cancelled cleanup. Source hashes accompany the generated harness under `$RUNNER_TEMP/ze-kernel-tests`.
2. `bash Vendor/ZeNative/ish/kernel/offload_tests/path_scope/run.sh`: compiles and runs existing native path-scope policy C cases with warnings as errors.
3. Full existing workflow device + simulator build: typechecks actual Swift/Objective-C bridging and links native libraries. The coordinator harness does not replace this check.
4. Device guest scenarios still to execute: concurrent parent plus two children in shared workspace; stop one child while sibling writes its own live output; timeout after output; stop blocked file-provider I/O; foreground/background transition under CPU load; AOJIT enabled/disabled comparison. Existing `scripts/ish-regress/regress_proc_exit_race.sh` is a guest script, not a host-only test.

At authoring, `python scripts/test-kernel-runtime.py --prepare-only` and scoped `git diff --check` completed successfully on Windows. Swift behavior/native tests require the macOS workflow and must be reported against its exact final SHA/run; the preparation result does **not** claim compilation or test execution.

## Rollback

Review the targeted source diff and revert the owning integration commit if runtime verification fails. No live rootfs, user workspace or installed application data was modified by this audit. Reference files and diff caches were kept under the system temporary directory; only audited source changes, this document, the manifest and test harness are repository deliverables.
