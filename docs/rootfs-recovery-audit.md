# Rootfs recovery: retained trees and transactional activation

## Source comparison and decision

Reference: `OpenMinis/OpenMinis@1a71df0f381cefde80bf912b723de6f9831bc177`, `RootfsManager.swift`, SHA-256 `26146bb788a166c87df4b0330eae39d043dcb94163da838425e7c238c40e428d` from the pinned kernel audit manifest.

The reference's `discardOldRootfs()` first recursively deletes the active rootfs. If deletion fails, it moves the remaining tree to a timestamped sibling, then attempts to delete that sibling and all earlier broken trees. Its documented failure case is an excessively deep tree causing `ENAMETOOLONG` and preventing every later install. That fallback restores availability, but the initial delete may already have removed user data and the later sweep deliberately deletes retained trees.

This implementation applies the same-directory rename mechanism while honoring the explicit requirement to retain user data: **no recursive deletion is attempted on an original tree**. Old trees use UUID-named sibling paths, and no history cleanup sweep is performed. This is a deliberate, documented deviation from the reference cleanup policy.

Baseline repository commit: `1e22d7df9ba7d970f50b77bb3f1e9684e3a8bf22`; baseline file SHA-256: `2f36db239c2332a9e7b553609019f497a1bc1d7e79d5dc9ae302c5b42b11eb4e`. A byte-preserving baseline copy was recorded in the system temporary `ze-rootfs-tests/RootfsManager.baseline.swift` before editing.

## Behavior and failure boundaries

- `installIfNeeded` checks the data directory, nonempty metadata file and architecture tag. Missing archive errors occur before touching the current rootfs.
- A complete new installation is extracted into a unique sibling staging directory. Its SQLite metadata is opened read-only, checked using `PRAGMA quick_check`, and required `paths`/`stats` columns are validated. The architecture tag is written only after extraction and metadata checks. Short ZIPs, truncated central directories, unsupported/incomplete entries and path traversal fail the installation.
- Only after preparation succeeds does `RootfsRecovery` rename the original directory entry to `.alpine-rootfs-recovery-<UUID>` and rename the prepared tree into its active location. POSIX rename does not traverse deep descendants. If activation fails, it attempts to rename the original back. If rollback also fails, the thrown error includes the retained original's exact path.
- Cleanup targets only the newly created staging tree. Failure to clean staging does not trigger deletion of any existing rootfs or recovery tree. A process termination between renames can leave an original recovery tree and staging tree on disk; neither is deleted on the next launch. An absent active tree is installed fresh, while the original remains available for explicit recovery.
- `reset` retires the entire tree by rename, retaining both file data and fakefs metadata. `keepUserData:true` writes an atomic pending-restore journal before renaming the original tree. The journal contains only the relative UUID directory name, so app container relocation does not invalidate the backup. On the next process launch, `installIfNeeded` restores `/root` before kernel boot and removes the journal only after restoration returns successfully. A failed install/restore retains the journal for retry. An interruption after journal write but before rename is completed from that journal on the next launch. The original backup remains intact after successful restore. The management view reads persistent pending status instead of retaining an unusable in-memory restore URL. `keepUserData:false` does not schedule automatic restoration but still preserves the old tree; disk space is therefore not reclaimed by reset. Retained directories require an explicit later cleanup decision.
- A reset with an already booted kernel sets the existing `didResetWhileBooted` flag immediately after retirement. Installation and user-data restoration reject replacement of a live kernel's mount and require a process restart.
- User-data restore first copies the backup into staging, then replaces `/root` by the same transaction. Copy/rename failures preserve the backup and original destination. The restored subtree is registered through a strict SQLite transaction: database open, source lookup, every binding/insert, host traversal and commit must succeed. Any error rolls back registration and retains the journal, so kernel boot does not proceed. Original fakefs stat blobs are copied, preserving guest symlink mode even when the host represents that link as an ordinary file; entries genuinely absent from source metadata receive host-derived file/directory mode. This does not claim preservation of hard-link inode identity across paths.
- Lifecycle operations are serialized by a recursive lock. This protects in-process calls; it is not a cross-process lock. Installation checks are structural and do not repeatedly run a full integrity scan on an already installed database. Deep internal corruption in an otherwise structurally present installed rootfs remains a separate diagnostic concern.

## Verification and artifacts

`python scripts/test-rootfs-recovery.py --prepare-only` succeeds on Windows and emits the full production Swift source, narrowly substituted fixture boundaries and a source-hash manifest into `$RUNNER_TEMP/ze-rootfs-tests` (system temporary directory when unset). Preparation does not establish Swift compilation or execution.

macOS CI command:

```sh
python3 scripts/test-rootfs-recovery.py
```

The script compiles the **complete production RootfsManager, ZIP reader and recovery helper**. It substitutes only the Documents URL, bundle archive URL, app logger and kernel boot-state boundary. It creates actual temporary filesystem trees and SQLite/ZIP files. Cases cover successful install and no-op, missing/corrupt/short/traversal archives preserving original bytes, architecture recovery retaining the old tree, a deep tree longer than absolute `PATH_MAX` moved without recursion, activation rollback, preserve failure, rollback failure with original retained, booted reset invalidation, a failed restore retaining its journal, an injected SQLite registration trigger failure retaining the journal, preservation of a fakefs symlink stat blob, an actual second-process restart that automatically restores the backup, interruption between journal publication and rename, and backup retention. Rename failure injection exercises production transaction paths.

Scoped `git diff --check` and fixture preparation passed locally. Swift runtime, full iOS build and device behavior must be reported separately against CI's final SHA. The two existing reset UI surfaces now explain automatic `/root` restoration after restart and explicitly state that retained directories do not release disk space. No installed rootfs or user data was modified by this work.

## Rollback

Revert the source/test/document commit to restore the previous code. Retained recovery directories are ordinary sibling trees and are not migrated destructively. To recover a retained full tree operationally, stop the app/guest first, preserve any current active tree separately, and rename the chosen recovery tree back to `alpine-rootfs`; never merge two fakefs metadata/data pairs or replace a live mount. No automated rollback or cleanup touches device data in this patch.
