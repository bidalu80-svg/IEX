# selfsign offline core

This package compiles the production `IPAPackageInspector` and `DeviceInstallCoordinator` directly.
It has no network, pairing, tunnel or signing backend and is not registered in the Ze Xcode project.

Run from the repository root with Swift 6 and system zlib:

```sh
python3 Installer/run-review.py
```

The runner creates a new `ipa-install-evidence/` (use `--evidence <new-path>` for another run),
compiles and executes tests, then compiles two isolated mutations and requires business assertion
failures. It preserves compile/test exit codes and logs. It never deletes existing evidence.
`swift test --package-path Installer` also works; the independent Python DEFLATE fixture test needs
the runner and will otherwise report SKIP. The fixtures contain synthetic headers, not runnable IPAs.

The inspector accepts single-disk stored/DEFLATE ZIPs with UTF-8/ASCII paths and bounded sizes.
ZIP64, encrypted ZIPs, all symbolic links, special files, case/Unicode aliases and file/directory
collisions fail closed. It validates local/central consistency and CRCs. Only a generated task
subdirectory of a caller-owned private workspace is cleaned on failure. The caller removes the
returned directory when finished. Limits are configurable and apply before allocation/decompression.
Static Mach-O checks include FAT/thin headers, architecture, iOS platform/minimum OS and encryption
load commands across the package. This is structural inspection, not signature/profile validation
or proof of executable behavior. Rejecting links/ZIP64 may exclude some otherwise usable packages.

The main-actor transaction treats upload and request acceptance as intermediate states. Installation
requires an independent exact bundle ID + marketing version + build query. Launch requires a separate
matching process query with a positive process ID. Even launch evidence says nothing about reboot or
expiry behavior. Cancellation invalidates callback tokens; after submission it leaves confirmation
pending. Restore always queries; it never resends install, and existing-target presence does not prove
which transaction installed it. The injected monotonic clock supports caller-driven timeout checks.
For real backends, persist the snapshot *before* sending install, serialize callbacks on the actor,
and implement independently verified queries; those integrations are deferred to the device phase.

Evidence marks signing/profile, device protocol, UI and real-device compatibility NOT TESTED.
There is no simulator run, screenshot or xcresult in this core scope. CI PASS covers implementation
assertions only and cannot certify iOS 27 installation, Apple trust, pairing, renewal or persistence.
