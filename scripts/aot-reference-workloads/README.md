The effective manifest targets OpenMinis app `1a71df0f381cefde80bf912b723de6f9831bc177`,
ish suite `0fd17a135e78b7a0cf08a4f5831217bbb76ed22f`. The reference clone's
`deps/ish` and Ze's vendored benchmark suite are absent. They are required
inputs, not replaced by Ze's former workloads. The workflow checks out the
pinned upstream suite; `prepare-aot-workloads.sh` runs its documented
`benchmark/aojit/install.sh <ish> <rootfs>` interface. Missing installer,
fixtures or guest workloads stop the job. That external interface still
requires a real recording run to validate.

`aot-targets.json` holds all 25 declared input module paths, GNU build-ids,
package versions, families and training workloads. It describes the next
recording, not the current binary images. `aot/VERSIONS.txt` and the Swift
`imageVersions` table describe the existing committed objects. In particular,
current `aot_sqlite.o` is Python `_sqlite3`, owned by python3. Node has no
object. Do not rewrite actual provenance to the desired versions prematurely.

The recorder checks every package and ELF identity before recording, requires
successful recording runs without FAIL (plus dry runs for the three locally
recorded crypto / ssl / pcre2 workloads), and enforces the reference
crypto / ssl / pcre2 floors (15000 / 5800 / 4100) and success markers. TLS
certificates are created on the host; requests, git and ripgrep are required.
PCRE2's available reference workload is copied here unchanged.

Exact old packages may need an Alpine snapshot/archive or the original APKs;
the current public repository may have removed them. Failure to install a
precise pin stops the workflow. Core packages are never upgraded to current
versions as a fallback. Node uses the engine's default mode, with no jitless
environment override, and has a 10800 second per-invocation deadline. The
workflow records each image in a separate matrix job (maximum four concurrent),
then requires all 25 image pairs and their exact identity ledgers before
publishing the combined artifact. The emitting ABI comes from a tiny raw
recording header; no guest /proc entry is assumed.

After a successful full recording, replace the 25 objects and VERSIONS.txt
from the **same** isolated `.aot-new/recorded/` artifact. Remove stale objects,
run `python3 scripts/sync-aot-objects.py` to refresh both linker lists and the
actual version table, then commit, build and run on a device. The SQLite row
switches from the legacy Python binding to libsqlite3 based on the linked
object metadata. Bundled r8 core restore is offered only when its build-id
matches the newly linked core image. A matching input build-id does not prove
identical native code, training coverage or speed. No new `.o` was generated
by this alignment task.
